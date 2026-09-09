import AppKit
import Combine
import SwiftUI

/// One live output for the entire application, independent of passage windows.
/// Owns the NSWindow directly; it deliberately has no NSWindowController.
@MainActor
final class LiveProjectionController: ObservableObject {
    let projector: ProjectorViewModel
    let library: BibleLibrary
    let defaults: UserDefaults
    private let sourceResolver: ((Bool) -> BibleSources)?
    private let refreshReader: VerseTargetModel
    var projectorWindowFactory: ((ProjectorViewModel) -> NSWindow?)?
    private(set) var ownedProjectorWindow: NSWindow?
    @Published private(set) var windowOpened = false
    @Published private(set) var isProjecting = false
    @Published private(set) var message: String?
    private var intent = UUID()
    private weak var preparingModel: VerseTargetModel?
    private var preparationStatus: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()
    private var preferenceTask: Task<Void, Never>?
    private var repositionTask: Task<Void, Never>?
    private var previousSources: BibleSources?
    private var previousDisplayID: Int
    private var previousTransparency: Bool

    init(projector: ProjectorViewModel? = nil, library: BibleLibrary? = nil,
         defaults: UserDefaults = .standard, sourceResolver: ((Bool) -> BibleSources)? = nil,
         refreshReader: VerseTargetModel? = nil) {
        self.projector = projector ?? ProjectorViewModel()
        self.library = library ?? .shared
        self.defaults = defaults
        self.sourceResolver = sourceResolver
        self.refreshReader = refreshReader ?? VerseTargetModel()
        previousDisplayID = defaults.integer(forKey: AppDefaultsKey.projectorScreenDisplayID)
        previousTransparency = defaults.bool(forKey: AppDefaultsKey.transparentBackground)
        previousSources = sources
        self.library.objectWillChange.sink { [weak self] _ in self?.schedulePreferences() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .sink { [weak self] _ in self?.schedulePreferences() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.scheduleProjectorReposition() }.store(in: &subscriptions)
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
    deinit { preferenceTask?.cancel(); repositionTask?.cancel() }

    var preferredDisplayID: Int { defaults.integer(forKey: AppDefaultsKey.projectorScreenDisplayID) }
    var sources: BibleSources {
        let primaryOnly = defaults.bool(forKey: AppDefaultsKey.showOnlyPrimary)
        return sourceResolver?(primaryOnly) ?? library.sources(
            primary: defaults.string(forKey: AppDefaultsKey.primaryBibleName) ?? bundledPrimaryBibleUrl?.absoluteString ?? "",
            secondary: defaults.string(forKey: AppDefaultsKey.secondaryBibleName) ?? bundledSecondaryBibleUrl?.absoluteString ?? "",
            primaryOnly: primaryOnly)
    }

    /// Reserve output before asynchronous navigation begins. New intents in ANY
    /// tab supersede older work; local navigation cancellation still cancels its
    /// own pending verse submission through VerseTargetModel's generation guard.
    func beginIntent(using model: VerseTargetModel) -> UUID {
        cancelPreparation()
        preparingModel = model
        let token = intent
        isProjecting = true
        message = nil
        preparationStatus = model.$isProjecting.dropFirst().sink { [weak self] projecting in
            guard let self, self.intent == token else { return }
            self.isProjecting = projecting
        }
        return token
    }

    @discardableResult
    private func cancelPreparation() -> UUID {
        preparationStatus = nil
        preparingModel?.cancelProjection()
        preparingModel = nil
        intent = UUID()
        isProjecting = false
        return intent
    }

    func publish(_ projection: PreparedProjection, intent token: UUID, preserveBlanking: Bool = false) {
        guard token == intent else { return }
        preparationStatus = nil
        preparingModel = nil
        isProjecting = false
        projector.project(projection.data, owner: projection.owner, preserveBlanking: preserveBlanking)
        openProjector()
    }
    func publishRow(_ projection: PreparedProjection) {
        let token = cancelPreparation()
        message = nil
        publish(projection, intent: token)
    }
    func requestProjection(owner: ProjectionOwner, using model: VerseTargetModel,
                           preserveBlanking: Bool = false, stopIfUnavailable: Bool = false) {
        let token = beginIntent(using: model)
        model.requestProjection(owner: owner, sources: sources) { [weak self, weak model] projection in
            guard let self, self.intent == token else { return }
            if let projection { self.publish(projection, intent: token, preserveBlanking: preserveBlanking) }
            else {
                self.message = model?.message
                if stopIfUnavailable { self.closeProjector() }
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
        let currentSources = sources
        if previousSources != currentSources {
            previousSources = currentSources
            cancelPreparation()
            if windowOpened, let owner = projector.projectionOwner {
                requestProjection(owner: owner, using: refreshReader, preserveBlanking: true, stopIfUnavailable: true)
            }
        }
        if previousDisplayID != preferredDisplayID {
            previousDisplayID = preferredDisplayID
            scheduleProjectorReposition()
        }
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
    private func repositionProjector(_ window: NSWindow) {
        guard let screen = resolveProjectorTargetScreen(preferredDisplayID: preferredDisplayID), window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: true)
    }
    func scheduleProjectorReposition() {
        repositionTask?.cancel()
        repositionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self, self.windowOpened, let window = self.ownedProjectorWindow else { return }
            self.repositionProjector(window)
        }
    }
    private func openProjector() {
        if let window = ownedProjectorWindow {
            applyProjectorAppearance(window)
            // Display notifications use the coalesced path, even during rapid verse activation.
            scheduleProjectorReposition()
            let priorKeyWindow = NSApplication.shared.keyWindow
            window.orderFrontRegardless()
            if let priorKeyWindow, priorKeyWindow !== window { priorKeyWindow.makeKey() }
            windowOpened = true
            return
        }
        guard !windowOpened, projector.projectionOwner != nil else { return }
        windowOpened = true
        if let projectorWindowFactory {
            // A nil fixture window suppresses display output while retaining live state.
            ownedProjectorWindow = projectorWindowFactory(projector)
        } else {
            ownedProjectorWindow = ProjectorView().environmentObject(projector).openNewWindow(with: AppWindowTitle.projector)
            if ownedProjectorWindow == nil { windowOpened = false }
        }
        if let window = ownedProjectorWindow { applyProjectorAppearance(window) }
    }
    func closeProjector() {
        cancelPreparation()
        repositionTask?.cancel()
        repositionTask = nil
        if let window = ownedProjectorWindow { window.close() }
        else { handleProjectorWindowClosed() }
    }
    func handleProjectorWindowClosed() {
        repositionTask?.cancel()
        let canceledModel = preparingModel
        preparationStatus = nil
        let modelCancellation = canceledModel?.cancelProjection(updateStatus: false)
        preparingModel = nil
        intent = UUID()
        let cancellationIntent = intent
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
            self.ownedProjectorWindow = nil
            self.windowOpened = false
        }
    }
    func toggleBlank() {
        guard windowOpened else { return }
        projector.toggleBlank()
    }
    func shutdown() {
        preferenceTask?.cancel()
        closeProjector()
        subscriptions.removeAll()
    }
}

extension MainWorkspaceController {
    func closeProjector() { liveProjection.closeProjector() }
    @objc func stopProjection(_ sender: Any?) { closeProjector() }
    @objc func toggleBlank(_ sender: Any?) { liveProjection.toggleBlank() }
    @objc func showPreview(_ sender: Any?) {
        guard windowOpened else { return }
        if preview.isShown { preview.performClose(sender); return }
        let size = resolveProjectorTargetScreen(preferredDisplayID: preferredDisplayID)?.frame.size ?? NSSize(width: 1920, height: 1080)
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
