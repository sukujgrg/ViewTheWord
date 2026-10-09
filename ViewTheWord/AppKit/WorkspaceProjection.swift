import AppKit
import Combine
import SwiftUI

/// One live output for the entire application, independent of passage windows.
/// Owns the NSWindow directly; it deliberately has no NSWindowController.
@MainActor
final class LiveProjectionController: ObservableObject {
    private enum Notice {
        case emptyCatalog
        case projectionFailure(String)

        var message: String {
            switch self {
            case .emptyCatalog: return BibleLibraryError.empty.localizedDescription
            case .projectionFailure(let message): return message
            }
        }
    }

    let projectionDisplays: ProjectionDisplayManager
    private let sleepPrevention: ProjectionSleepPrevention
    private let displayOwner = UUID()
    private var displayObservation: UUID?
    private(set) var activeMonitor: ProjectionMonitorTarget?
    let altView: AltViewProjectionService
    let projector: ProjectorViewModel
    let library: BibleLibrary
    let defaults: UserDefaults
    private let refreshReader: VerseTargetModel
    var projectorWindowFactory: ((ProjectorViewModel) -> NSWindow?)?
    private(set) var ownedProjectorWindow: NSWindow?
    @Published private(set) var windowOpened = false
    @Published private(set) var isProjecting = false
    @Published private var notice: Notice?
    @Published private(set) var source: ProjectionSource?
    private var intent = UUID()
    private var pendingSource: ProjectionSource?
    private var tabSources: [UUID: BibleSources] = [:]
    private var isClosing = false
    private weak var preparingModel: VerseTargetModel?
    private var subscriptions = Set<AnyCancellable>()
    private var preferenceTask: Task<Void, Never>?
    private var repositionTask: Task<Void, Never>?
    private var previousTransparency: Bool

    init(projector: ProjectorViewModel? = nil, library: BibleLibrary? = nil,
         defaults: UserDefaults = .standard,
         refreshReader: VerseTargetModel? = nil, altView: AltViewProjectionService? = nil,
         projectionDisplays: ProjectionDisplayManager? = nil, sleepPrevention: ProjectionSleepPrevention? = nil) {
        self.altView = altView ?? AltViewProjectionService(defaults: defaults)
        self.projector = projector ?? ProjectorViewModel()
        self.library = library ?? .shared
        self.defaults = defaults
        self.refreshReader = refreshReader ?? VerseTargetModel()
        self.projectionDisplays = projectionDisplays ?? ProjectionDisplayManager(defaults: defaults)
        self.sleepPrevention = sleepPrevention ?? ProjectionSleepPrevention()
        previousTransparency = defaults.bool(forKey: AppDefaultsKey.transparentBackground)
        displayObservation = self.projectionDisplays.observe { [weak self] in self?.projectionDisplaysChanged() }
        // Catalog recovery retracts only its own notice, even after output has
        // stopped or every passage tab has closed. It never resumes projection.
        self.library.$urls.map(\.isEmpty).removeDuplicates()
            .sink { [weak self] isEmpty in
                guard !isEmpty, let self, case .emptyCatalog = self.notice else { return }
                self.dismissMessage()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .sink { [weak self] _ in self?.schedulePreferences() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.ownedProjectorWindow else { return }
                self.handleProjectorWindowClosed()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .closeProjectorRequested)
            .sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.ownedProjectorWindow else { return }
                self.closeProjector()
            }.store(in: &subscriptions)
    }
    deinit {
        preferenceTask?.cancel()
        repositionTask?.cancel()
        sleepPrevention.stop()
        let displays = projectionDisplays
        let observation = displayObservation
        let owner = displayOwner
        let window = ownedProjectorWindow
        DispatchQueue.main.async {
            if let observation { displays.removeObserver(observation) }
            window?.close()
            displays.unlock(owner: owner)
        }
    }

    var message: String? { notice?.message }

    /// Only the tab supplying live output can refresh its translations. Keep the
    /// latest choices while another tab prepares output; that explicit intent wins.
    func updateSources(_ sources: BibleSources?, from tabID: UUID) {
        guard tabSources[tabID] != sources else { return }
        tabSources[tabID] = sources
        if pendingSource?.tabID == tabID, pendingSource?.sources != sources { cancelPreparation() }
        refreshSourceIfNeeded()
    }

    func detachTab(_ tabID: UUID) {
        tabSources.removeValue(forKey: tabID)
        if let source, source.tabID == tabID {
            self.source = ProjectionSource(tabID: nil, sources: source.sources)
        }
        if let pendingSource, pendingSource.tabID == tabID {
            if preparingModel === refreshReader {
                // An already-requested live refresh has its own reader and can
                // finish after its tab closes. Subsequent output stays frozen.
                self.pendingSource = ProjectionSource(tabID: nil, sources: pendingSource.sources)
            } else { cancelPreparation() }
        }
        refreshSourceIfNeeded()
    }

    private func refreshSourceIfNeeded() {
        guard !isClosing, pendingSource == nil, windowOpened, let source, let tabID = source.tabID,
              let owner = projector.projectionOwner else { return }
        guard let sources = tabSources[tabID] else {
            notice = .emptyCatalog
            closeProjector(preservingMessage: true)
            return
        }
        guard sources != source.sources else { return }
        requestProjection(owner: owner, from: tabID, sources: sources, using: refreshReader,
                          refreshingLiveOutput: true)
    }

    /// Reserve output before asynchronous navigation begins. New intents in ANY
    /// tab supersede older work; local navigation cancellation still cancels its
    /// own pending verse submission through VerseTargetModel's generation guard.
    func beginIntent(from tabID: UUID, sources: BibleSources, using model: VerseTargetModel, clearMessage: Bool = true) -> UUID {
        cancelPreparation()
        tabSources[tabID] = sources
        pendingSource = ProjectionSource(tabID: tabID, sources: sources)
        preparingModel = model
        isProjecting = true
        if clearMessage { dismissMessage() }
        return intent
    }

    @discardableResult
    private func cancelPreparation() -> UUID {
        let canceledModel = preparingModel
        preparingModel = nil
        pendingSource = nil
        intent = UUID()
        isProjecting = false
        // Invalidate ownership before invoking the model's cancellation callback.
        canceledModel?.cancelProjection()
        return intent
    }

    func finishIntent(_ token: UUID) {
        guard token == intent, pendingSource != nil else { return }
        preparingModel = nil
        pendingSource = nil
        intent = UUID()
        isProjecting = false
        schedulePreferences()
    }

    func publish(_ projection: PreparedProjection, intent token: UUID, preserveBlanking: Bool = false) {
        guard token == intent, let pendingSource, pendingSource.sources == projection.sources else { return }
        projectionDisplays.refresh()
        guard token == intent else { return }
        // A refresh may stop an output whose monitor disappeared. Background
        // translation work must never reopen it; only a fresh explicit intent can.
        guard !preserveBlanking || activeMonitor != nil else { finishIntent(token); return }
        guard let monitor = projectionDisplays.resolvedMonitor() else {
            finishIntent(token)
            notice = .projectionFailure(projectionDisplays.selectionProblem ?? "Choose a projection monitor in Settings.")
            return
        }
        guard openProjector(on: monitor) else {
            finishIntent(token)
            notice = .projectionFailure("The projection monitor is not ready. Choose it in Settings and project again.")
            return
        }
        finishIntent(token)
        source = pendingSource
        isClosing = false
        projector.project(projection.data, owner: projection.owner, preserveBlanking: preserveBlanking)
        if let window = ownedProjectorWindow {
            if !preserveBlanking { bringProjectorToFront(window) }
            sleepPrevention.start()
        }
        altView.publish(projection, blanked: projector.isBlanked, explicit: !preserveBlanking)
    }
    func publishRow(_ projection: PreparedProjection, from tabID: UUID) {
        let token = cancelPreparation()
        tabSources[tabID] = projection.sources
        pendingSource = ProjectionSource(tabID: tabID, sources: projection.sources)
        dismissMessage()
        publish(projection, intent: token)
    }
    func requestProjection(owner: ProjectionOwner, from tabID: UUID, sources: BibleSources, using model: VerseTargetModel,
                           refreshingLiveOutput: Bool = false) {
        // A deferred translation refresh must not erase the explanation for a
        // newer explicit projection that failed before this refresh could run.
        let token = beginIntent(from: tabID, sources: sources, using: model, clearMessage: !refreshingLiveOutput)
        model.requestProjection(owner: owner, sources: sources, onCancelled: { [weak self] in
            self?.finishIntent(token)
        }) { [weak self, weak model] projection in
            guard let self, self.intent == token else { return }
            if let projection { self.publish(projection, intent: token, preserveBlanking: refreshingLiveOutput) }
            else {
                self.finishIntent(token)
                self.notice = (model?.message).map { .projectionFailure($0) }
                // The shared controller owns this error in every passage tab.
                // Avoid retaining a second, undismissable copy in the source tab.
                model?.message = nil
                if refreshingLiveOutput { self.closeProjector(preservingMessage: true) }
            }
        }
    }

    private func schedulePreferences() {
        guard preferenceTask == nil else { return }
        preferenceTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.preferenceTask = nil
            self.refreshPreferences()
        }
    }
    func refreshPreferences() {
        refreshSourceIfNeeded()
        let transparent = defaults.bool(forKey: AppDefaultsKey.transparentBackground)
        if transparent != previousTransparency {
            previousTransparency = transparent
            if let window = ownedProjectorWindow { applyProjectorAppearance(window) }
        }
    }
    private func applyProjectorAppearance(_ window: NSWindow) {
        let transparent = defaults.bool(forKey: AppDefaultsKey.transparentBackground)
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .black
    }
    private func projectionDisplaysChanged() {
        guard let target = activeMonitor else { return }
        if let problem = projectionDisplays.problem(for: target) {
            notice = .projectionFailure("Projection stopped. \(problem) Project again when the monitor is ready.")
            closeProjector(preservingMessage: true)
        } else { scheduleProjectorReposition() }
    }
    private func repositionProjector(_ window: NSWindow) {
        guard let target = activeMonitor, let monitor = projectionDisplays.resolve(target) else {
            notice = .projectionFailure("Projection stopped because its monitor is unavailable. Reconnect it and project again.")
            closeProjector(preservingMessage: true)
            return
        }
        let frame: CGRect
        if projectorWindowFactory != nil { frame = monitor.frame }
        else {
            guard let screen = ProjectionScreenResolver.screen(for: monitor) else {
                notice = .projectionFailure("Projection stopped because its monitor is unavailable. Reconnect it and project again.")
                closeProjector(preservingMessage: true)
                return
            }
            // Use the resolved screen's current geometry, not an earlier
            // inventory frame during a rapid rearrangement of displays.
            frame = screen.frame
        }
        guard window.frame != frame else { return }
        window.setFrame(frame, display: true)
    }
    func scheduleProjectorReposition() {
        repositionTask?.cancel()
        repositionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, self.activeMonitor != nil, let window = self.ownedProjectorWindow else { return }
            self.repositionProjector(window)
        }
    }
    /// Selection is validated once here for all callers. Only explicit passage
    /// publication raises output above an existing full-screen presentation.
    private func openProjector(on monitor: ProjectionMonitor) -> Bool {
        if activeMonitor != nil {
            guard activeMonitor?.identity == monitor.identity else { return false }
            if let window = ownedProjectorWindow {
                applyProjectorAppearance(window)
                scheduleProjectorReposition()
            }
            return true
        }
        guard !projectionDisplays.isLocked else { return false }
        let window: NSWindow?
        if let projectorWindowFactory {
            // A nil fixture suppresses native output; it holds no sleep activity.
            window = projectorWindowFactory(projector)
        } else {
            guard let screen = ProjectionScreenResolver.screen(for: monitor) else { return false }
            window = ProjectorView().environmentObject(projector).makeProjectorWindow(with: AppWindowTitle.projector, on: screen)
        }
        ownedProjectorWindow = window
        activeMonitor = monitor.target
        projectionDisplays.lock(monitor.target, owner: displayOwner)
        windowOpened = true
        if let window {
            applyProjectorAppearance(window)
        }
        return true
    }
    private func bringProjectorToFront(_ window: NSWindow) {
        let priorKeyWindow = NSApplication.shared.keyWindow
        window.orderFrontRegardless()
        if let priorKeyWindow, priorKeyWindow !== window { priorKeyWindow.makeKey() }
    }
    func dismissMessage() { notice = nil }

    func closeProjector(preservingMessage: Bool = false) {
        if !preservingMessage { dismissMessage() }
        cancelPreparation()
        repositionTask?.cancel()
        repositionTask = nil
        if let window = ownedProjectorWindow { window.close() }
        else { handleProjectorWindowClosed() }
    }
    func handleProjectorWindowClosed() {
        sleepPrevention.stop()
        activeMonitor = nil
        projectionDisplays.unlock(owner: displayOwner)
        altView.stop()
        isClosing = true
        repositionTask?.cancel()
        let canceledModel = preparingModel
        preparingModel = nil
        pendingSource = nil
        intent = UUID()
        let cancellationIntent = intent
        let modelCancellation = canceledModel?.cancelProjection(updateStatus: false)
        let revision = projector.revision
        let closingWindow = ownedProjectorWindow
        // Notifications arrive inside AppKit teardown. Clear the closed output,
        // but preserve any newer publication/window and any new preparation.
        DispatchQueue.main.async { [weak self] in
            if let modelCancellation { canceledModel?.finishProjectionCancellation(modelCancellation) }
            guard let self, self.projector.revision == revision,
                  self.ownedProjectorWindow === closingWindow else { return }
            self.repositionTask = nil
            if self.intent == cancellationIntent { self.isProjecting = false }
            self.projector.clearProjection()
            self.source = nil
            self.ownedProjectorWindow = nil
            self.windowOpened = false
        }
    }
    func toggleBlank() {
        guard windowOpened else { return }
        projector.toggleBlank()
        altView.setBlanked(projector.isBlanked)
    }
    func shutdown() {
        preferenceTask?.cancel()
        closeProjector()
        altView.disconnect()
        projectionDisplays.closeIdentification()
        if let displayObservation { projectionDisplays.removeObserver(displayObservation) }
        displayObservation = nil
        subscriptions.removeAll()
    }
}

extension MainWorkspaceController {
    func closeProjector() { liveProjection.closeProjector() }
    @objc func dismissProjectionMessage(_ sender: Any?) { liveProjection.dismissMessage() }
    @objc func stopProjection(_ sender: Any?) { closeProjector() }
    @objc func toggleBlank(_ sender: Any?) { liveProjection.toggleBlank() }
    @objc func showPreview(_ sender: Any?) {
        guard windowOpened else { return }
        if preview.isShown { preview.performClose(sender); return }
        let size = liveProjection.ownedProjectorWindow?.frame.size ?? liveProjection.projectionDisplays.resolvedMonitor()?.frame.size ?? NSSize(width: 1920, height: 1080)
        preview.behavior = .transient
        preview.contentViewController = NSHostingController(rootView: ProjectionPreview(outputSize: size).environmentObject(projector))
        preview.show(relativeTo: previewButton.bounds, of: previewButton, preferredEdge: .maxY)
    }
}

private struct ProjectionPreview: View {
    let outputSize: CGSize
    var body: some View {
        let scale = min(520 / max(1, outputSize.width), 320 / max(1, outputSize.height))
        VStack(alignment: .leading, spacing: 10) {
            ProjectorView()
                .frame(width: outputSize.width, height: outputSize.height)
                .background(.black)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: outputSize.width * scale, height: outputSize.height * scale, alignment: .topLeading)
                .clipped()
            Text("Live output preview").font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }
}
