import AppKit
import Combine
import SwiftUI

/// The sole committed scripture publisher and owner of every native output window.
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

    struct NativeOutput {
        let id: UUID
        let instance = UUID()
        let monitor: ProjectionMonitorTarget
        let appearance: NativeOutputRenderModel
        let window: NSWindow?
    }
    let projectionDisplays: ProjectionDisplayManager
    let outputs: OutputConfigurationStore
    let discovery: AltViewDiscoveryService
    private let sleepPrevention: ProjectionSleepPrevention
    private var displayObservation: UUID?
    private var observedDisplays: [ProjectionMonitor] = []
    @Published private(set) var nativeOutputs: [UUID: NativeOutput] = [:]
    @Published private(set) var altViewServices: [UUID: AltViewProjectionService] = [:]
    private var remoteSubscriptions: [UUID: AnyCancellable] = [:]
    private let serviceFactory: @MainActor (AltViewOutputAssignment, AltViewDiscoveryService) -> AltViewProjectionService
    let projector: ProjectorViewModel
    let library: BibleLibrary
    let defaults: UserDefaults
    private let refreshReader: VerseTargetModel
    // Fixtures may suppress or record windows without physical display output.
    var nativeWindowFactory: ((OutputDestination, NativeOutputRenderModel, ProjectorViewModel) -> NSWindow?)?
    @Published private(set) var windowOpened = false // committed output, including remote-only output
    var hasNativeWindows: Bool { !nativeOutputs.isEmpty }
    @Published private(set) var isProjecting = false
    @Published private var notice: Notice?
    @Published private(set) var source: ProjectionSource?
    private var intent = UUID()
    private var pendingSource: ProjectionSource?
    // A close/loss revokes only that destination's pending opening permission.
    private struct NativeOpeningIntent {
        let token: UUID
        let monitorIdentity: String?
    }
    private var nativeOpeningIntents: [UUID: NativeOpeningIntent] = [:]
    private var tabSources: [UUID: BibleSources] = [:]
    private var isClosing = false
    private var didRestoreOutputs = false
    private weak var preparingModel: VerseTargetModel?
    private var subscriptions = Set<AnyCancellable>()
    private var preferenceTask: Task<Void, Never>?
    private var repositionTask: Task<Void, Never>?

    init(projector: ProjectorViewModel? = nil, library: BibleLibrary? = nil,
         defaults: UserDefaults = .standard, refreshReader: VerseTargetModel? = nil,
         projectionDisplays: ProjectionDisplayManager? = nil, sleepPrevention: ProjectionSleepPrevention? = nil,
         outputs: OutputConfigurationStore? = nil, discovery: AltViewDiscoveryService? = nil,
         altViewServiceFactory: @escaping @MainActor (AltViewOutputAssignment, AltViewDiscoveryService) -> AltViewProjectionService = {
             AltViewProjectionService(destination: $0.receiver, template: $0.template, discovery: $1)
         }) {
        self.projector = projector ?? ProjectorViewModel()
        self.library = library ?? .shared; self.defaults = defaults
        self.refreshReader = refreshReader ?? VerseTargetModel()
        let displays = projectionDisplays ?? ProjectionDisplayManager(defaults: defaults)
        self.projectionDisplays = displays
        self.outputs = outputs ?? OutputConfigurationStore(defaults: defaults, displays: displays)
        self.discovery = discovery ?? AltViewDiscoveryService()
        self.serviceFactory = altViewServiceFactory
        self.sleepPrevention = sleepPrevention ?? ProjectionSleepPrevention()
        observedDisplays = displays.displays
        displayObservation = displays.observe { [weak self] in self?.projectionDisplaysChanged() }
        self.library.$urls.map(\.isEmpty).removeDuplicates().sink { [weak self] isEmpty in
            guard !isEmpty, let self, case .emptyCatalog = self.notice else { return }
            self.dismissMessage()
        }.store(in: &subscriptions)
        self.outputs.objectWillChange.sink { [weak self] _ in self?.schedulePreferences() }.store(in: &subscriptions)
        self.outputs.$configuration.sink { [weak self] configuration in
            guard let self else { return }
            // Revoke against every saved edit, before deferred preference work
            // coalesces changes. Restoring an assignment cannot revive an old intent.
            self.nativeOpeningIntents = self.nativeOpeningIntents.filter { id, opening in
                guard let destination = configuration.destinations.first(where: { $0.id == id }),
                      destination.enabled, let assignment = destination.native else { return false }
                return assignment.monitor?.identity == opening.monitorIdentity
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification).sink { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  let output = self.nativeOutputs.values.first(where: { $0.window === window }) else { return }
            self.handleNativeWindowClosed(output)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .closeProjectorRequested).sink { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  let output = self.nativeOutputs.values.first(where: { $0.window === window }) else { return }
            self.closeNativeOutput(output.id)
        }.store(in: &subscriptions)
        self.outputs.receiverIsAvailable = { [weak self] destination in
            guard let self, let assignment = destination.altView, let receiver = assignment.receiver else { return false }
            if self.altViewServices[destination.id]?.status.connected == true { return true }
            let identity = assignment.receiverID ?? receiver.receiverIdentity
            return self.discovery.receivers.contains { $0.account == receiver.account || (identity != nil && $0.receiverIdentity == identity) }
        }
        syncDestinations()
    }
    isolated deinit {
        preferenceTask?.cancel(); repositionTask?.cancel(); sleepPrevention.stop()
        if let displayObservation { projectionDisplays.removeObserver(displayObservation) }
        for output in nativeOutputs.values { output.window?.close(); projectionDisplays.unlock(owner: output.id) }
        for service in altViewServices.values { service.disconnect() }
        discovery.shutdown()
    }

    /// App launch calls this once. Native clocks need no committed scripture;
    /// remote restoration still connects without publishing or taking output.
    func restoreOutputConnections() {
        guard !didRestoreOutputs else { return }; didRestoreOutputs = true
        for destination in outputs.destinations {
            if destination.native != nil { if destination.enabled { showStandby(destination.id) }; continue }
            guard let receiver = destination.altView?.receiver, outputs.conflict(for: destination) == nil else { continue }
            altViewServices[destination.id]?.connect(to: receiver, code: "")
        }
    }
    private func syncDestinations() {
        let configured = Set(outputs.destinations.filter { $0.altView != nil }.map(\.id))
        for id in Array(altViewServices.keys) where !configured.contains(id) {
            altViewServices.removeValue(forKey: id)?.disconnect(); remoteSubscriptions.removeValue(forKey: id)
        }
        for destination in outputs.destinations {
            if let assignment = destination.altView {
                if altViewServices[destination.id] == nil {
                    let service = serviceFactory(assignment, discovery)
                    service.validateReceiver = { [weak self] receiver, identity in
                        guard let self, var destination = self.outputs.destination(destination.id), var assignment = destination.altView else { return "Output no longer exists." }
                        assignment.receiver = receiver; assignment.receiverID = identity
                        destination.assignment = .altView(assignment)
                        return self.outputs.conflict(for: destination)
                    }
                    service.onConfigurationChanged = { [weak self] change in
                        guard let self, var saved = self.outputs.destination(destination.id), var value = saved.altView else { return }
                        switch change {
                        case .template(let template): value.template = template
                        case .paired(let receiver, let identity): value.receiver = receiver; value.receiverID = identity
                        }
                        saved.assignment = .altView(value)
                        _ = self.outputs.update(saved)
                    }
                    altViewServices[destination.id] = service
                    remoteSubscriptions[destination.id] = service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send(); self?.schedulePreferences() }
                }
                if !destination.enabled, let service = altViewServices[destination.id], service.hasPublication { service.stop() }
                if outputs.conflict(for: destination) != nil,
                   let service = altViewServices[destination.id], service.isEnabled { service.stop() }
            }
        }
        for output in Array(nativeOutputs.values) {
            guard let destination = outputs.destination(output.id), destination.enabled,
                  let assignment = destination.native, assignment.monitor?.identity == output.monitor.identity,
                  outputs.conflict(for: destination) == nil, let profile = outputs.profile(assignment.profileID) else {
                closeNativeOutput(output.id); continue
            }
            // Turning off a standalone clock must release its window/monitor.
            // With committed scripture, preserve the output and its blank state.
            // An appearance change must not revoke a pending explicit verse.
            if projector.projection == nil, pendingSource == nil, profile.standby == .hidden {
                closeNativeOutput(output.id); continue
            }
            if output.appearance.profile != profile { output.appearance.profile = profile }
            if let window = output.window { window.title = destination.name; applyAppearance(window, profile: profile) }
        }
    }
    @discardableResult func connectAltView(_ id: UUID, to receiver: AltViewDestination, code: String) -> String? {
        guard var destination = outputs.destination(id), var assignment = destination.altView else { return "Choose an AltView output." }
        if assignment.receiver?.account != receiver.account { assignment.receiverID = receiver.receiverIdentity }
        assignment.receiver = receiver; destination.assignment = .altView(assignment)
        if let issue = outputs.update(destination) { return issue }
        syncDestinations()
        altViewServices[id]?.connect(to: receiver, code: code)
        return nil
    }
    var outputSummary: String {
        let names = outputs.destinations.filter(\.enabled).map(\.name)
        return names.isEmpty ? "No outputs enabled" : "Outputs: " + names.joined(separator: ", ")
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
    func beginIntent(from tabID: UUID, sources: BibleSources, using model: VerseTargetModel, clearMessage: Bool = true, refreshingLiveOutput: Bool = false) -> UUID {
        cancelPreparation()
        if !refreshingLiveOutput { authorizeNativeOpenings(intent) }
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
        // A hidden standalone output may have been retained only for this work.
        // Reconcile it after cancellation without tearing down a newer intent.
        schedulePreferences()
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
        guard !preserveBlanking || windowOpened else { finishIntent(token); return }
        var available = false
        var problems: [String] = []
        for destination in outputs.destinations where destination.enabled {
            if let issue = outputs.conflict(for: destination) { problems.append("\(destination.name): \(issue)"); continue }
            if let assignment = destination.native {
                // Automatic refresh can update an existing output, never reopen it.
                if nativeOutputs[destination.id] == nil {
                    if preserveBlanking { continue }
                    guard nativeOpeningIntents[destination.id]?.token == token,
                          nativeOpeningIntents[destination.id]?.monitorIdentity == assignment.monitor?.identity else {
                        problems.append("\(destination.name): Project again to reopen this output."); continue
                    }
                }
                guard let target = assignment.monitor else { problems.append("\(destination.name): Choose a monitor in Manage Outputs."); continue }
                guard let monitor = projectionDisplays.resolve(target), let profile = outputs.profile(assignment.profileID) else {
                    problems.append("\(destination.name): \(projectionDisplays.problem(for: target) ?? "Monitor unavailable.")"); continue
                }
                if openNativeOutput(destination, monitor: monitor, profile: profile) { available = true }
                else { problems.append("\(destination.name): Monitor is not ready.") }
            } else if let service = altViewServices[destination.id], service.isEnabled, service.status.failureReason == nil {
                available = true
            }
        }
        guard available else {
            finishIntent(token)
            notice = .projectionFailure(problems.isEmpty ? "Enable and connect an output in Manage Outputs." : problems.joined(separator: "\n"))
            return
        }
        finishIntent(token)
        source = pendingSource
        isClosing = false; windowOpened = true
        projector.project(projection.data, owner: projection.owner, preserveBlanking: preserveBlanking)
        for output in nativeOutputs.values {
            if let window = output.window, !preserveBlanking { bringProjectorToFront(window) }
        }
        updateSleepPrevention()
        for destination in outputs.destinations where destination.enabled && outputs.conflict(for: destination) == nil {
            altViewServices[destination.id]?.publish(projection, blanked: projector.isBlanked, explicit: !preserveBlanking)
        }
        if !problems.isEmpty { notice = .projectionFailure(problems.joined(separator: "\n")) }
    }

    func publishRow(_ projection: PreparedProjection, from tabID: UUID) {
        let token = cancelPreparation()
        authorizeNativeOpenings(token)
        tabSources[tabID] = projection.sources
        pendingSource = ProjectionSource(tabID: tabID, sources: projection.sources)
        dismissMessage()
        publish(projection, intent: token)
    }
    func requestProjection(owner: ProjectionOwner, from tabID: UUID, sources: BibleSources, using model: VerseTargetModel,
                           refreshingLiveOutput: Bool = false) {
        // A deferred translation refresh must not erase the explanation for a
        // newer explicit projection that failed before this refresh could run.
        let token = beginIntent(from: tabID, sources: sources, using: model, clearMessage: !refreshingLiveOutput, refreshingLiveOutput: refreshingLiveOutput)
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
        syncDestinations()
        if windowOpened, nativeOutputs.isEmpty, !altViewServices.values.contains(where: \.hasPublication) {
            // A remote failure clears obsolete live data, never another output's preparation.
            deferClearCommittedProjection()
        }
        refreshSourceIfNeeded()
    }
    private func applyAppearance(_ window: NSWindow, profile: NativeOutputProfile) {
        window.isOpaque = !profile.transparent && profile.background.alpha == 1
        window.backgroundColor = window.isOpaque ? profile.background.nsColor : .clear
    }
    private func projectionDisplaysChanged() {
        // Label/lock changes update editors; only inventory changes affect lifecycle.
        guard observedDisplays != projectionDisplays.displays else { return }
        observedDisplays = projectionDisplays.displays
        for destination in outputs.destinations {
            if nativeOpeningIntents[destination.id]?.token == intent,
               let target = destination.native?.monitor, projectionDisplays.problem(for: target) != nil {
                nativeOpeningIntents.removeValue(forKey: destination.id)
            }
        }
        for output in Array(nativeOutputs.values) {
            if let problem = projectionDisplays.problem(for: output.monitor) {
                notice = .projectionFailure("\(outputs.destination(output.id)?.name ?? "Output") stopped. \(problem) Project again when the monitor is ready.")
                closeNativeOutput(output.id)
            } else if let destination = outputs.destination(output.id), let conflict = outputs.conflict(for: destination) {
                notice = .projectionFailure(conflict); closeNativeOutput(output.id)
            }
        }
        if pendingSource != nil, nativeOutputs.isEmpty,
           !altViewServices.values.contains(where: \.hasPublication), !hasEligiblePendingDestination { cancelPreparation() }
        scheduleProjectorReposition()
    }
    private func reposition(_ output: NativeOutput) {
        guard let window = output.window, let monitor = projectionDisplays.resolve(output.monitor) else { return }
        let frame: CGRect
        if nativeWindowFactory != nil { frame = monitor.frame }
        else {
            guard let screen = ProjectionScreenResolver.screen(for: monitor) else { closeNativeOutput(output.id); return }
            frame = screen.frame
        }
        if window.frame != frame { window.setFrame(frame, display: true) }
    }
    func scheduleProjectorReposition() {
        repositionTask?.cancel()
        repositionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled, let self else { return }
            for output in Array(self.nativeOutputs.values) { self.reposition(output) }
            self.repositionTask = nil
        }
    }
    private func openNativeOutput(_ destination: OutputDestination, monitor: ProjectionMonitor, profile: NativeOutputProfile) -> Bool {
        if let output = nativeOutputs[destination.id] {
            guard output.monitor.identity == monitor.identity else { return false }
            output.appearance.profile = profile
            if let window = output.window { applyAppearance(window, profile: profile) }
            scheduleProjectorReposition(); return true
        }
        guard !nativeOutputs.values.contains(where: { $0.monitor.identity == monitor.identity }) else { return false }
        let appearance = NativeOutputRenderModel(profile: profile)
        let window: NSWindow?
        if let nativeWindowFactory { window = nativeWindowFactory(destination, appearance, projector) }
        else {
            guard let screen = ProjectionScreenResolver.screen(for: monitor) else { return false }
            window = NativeOutputView(appearance: appearance).environmentObject(projector).makeProjectorWindow(with: destination.name, on: screen)
        }
        let output = NativeOutput(id: destination.id, monitor: monitor.target, appearance: appearance, window: window)
        nativeOutputs[destination.id] = output
        projectionDisplays.lock(monitor.target, owner: destination.id)
        if let window {
            window.setFrame(monitor.frame, display: false)
            applyAppearance(window, profile: profile)
        }
        return true
    }
    /// An explicit local standby action. It never changes scripture, ownership or AltView.
    func showStandby(_ id: UUID) {
        guard projector.projection == nil || projector.isBlanked,
              let destination = outputs.destination(id), destination.enabled,
              let assignment = destination.native, let target = assignment.monitor,
              let profile = outputs.profile(assignment.profileID), profile.standby == .clock,
              outputs.conflict(for: destination) == nil, let monitor = projectionDisplays.resolve(target),
              openNativeOutput(destination, monitor: monitor, profile: profile) else { return }
        if let window = nativeOutputs[id]?.window { bringProjectorToFront(window) }
        updateSleepPrevention()
    }
    /// Called only by an explicit profile clock action, never by discovery,
    /// passive preference refresh or a monitor reconnect.
    func showStandbyOutputs(using profileID: UUID) {
        for destination in outputs.destinations where destination.native?.profileID == profileID {
            showStandby(destination.id)
        }
    }
    private func updateSleepPrevention() {
        if nativeOutputs.values.contains(where: { $0.window != nil }) { sleepPrevention.start() }
        else { sleepPrevention.stop() }
    }
    private func bringProjectorToFront(_ window: NSWindow) {
        let priorKeyWindow = NSApplication.shared.keyWindow
        window.orderFrontRegardless()
        if let priorKeyWindow, priorKeyWindow !== window { priorKeyWindow.makeKey() }
    }
    func dismissMessage() { notice = nil }

    private func authorizeNativeOpenings(_ token: UUID) {
        nativeOpeningIntents = Dictionary(uniqueKeysWithValues: outputs.destinations.filter { $0.enabled && $0.native != nil }.map { ($0.id, NativeOpeningIntent(token: token, monitorIdentity: $0.native?.monitor?.identity)) })
    }
    private var hasEligiblePendingDestination: Bool {
        guard pendingSource != nil else { return false }
        return outputs.destinations.contains { destination in
            guard destination.enabled, outputs.conflict(for: destination) == nil else { return false }
            if let assignment = destination.native, let target = assignment.monitor {
                return nativeOpeningIntents[destination.id]?.token == intent &&
                    nativeOpeningIntents[destination.id]?.monitorIdentity == target.identity && projectionDisplays.resolve(target) != nil
            }
            if let service = altViewServices[destination.id] { return service.isEnabled && service.status.failureReason == nil }
            return false
        }
    }
    func closeNativeOutput(_ id: UUID) {
        guard let output = nativeOutputs[id] else { return }
        if let window = output.window { window.close() }
        else { handleNativeWindowClosed(output) }
    }
    private func handleNativeWindowClosed(_ output: NativeOutput) {
        guard nativeOutputs[output.id]?.instance == output.instance else { return }
        nativeOutputs.removeValue(forKey: output.id)
        nativeOpeningIntents.removeValue(forKey: output.id)
        projectionDisplays.unlock(owner: output.id)
        updateSleepPrevention()
        guard windowOpened, nativeOutputs.isEmpty, !altViewServices.values.contains(where: \.hasPublication) else { return }
        if !hasEligiblePendingDestination {
            let canceledModel = preparingModel
            preparingModel = nil; pendingSource = nil; intent = UUID()
            let cancellation = canceledModel?.cancelProjection(updateStatus: false)
            DispatchQueue.main.async {
                if let cancellation { canceledModel?.finishProjectionCancellation(cancellation) }
            }
        }
        deferClearCommittedProjection()
    }
    func closeProjector(preservingMessage: Bool = false) {
        if !preservingMessage { dismissMessage() }
        cancelPreparation(); repositionTask?.cancel(); repositionTask = nil
        for service in altViewServices.values { service.stop() }
        isClosing = true
        // Confidence remains a clock on Stop, without a scripture owner.
        for output in Array(nativeOutputs.values) where output.appearance.profile.standby != .clock { closeNativeOutput(output.id) }
        deferClearCommittedProjection()
    }
    private func deferClearCommittedProjection() {
        isClosing = true
        let revision = projector.revision
        let cancellationIntent = intent
        DispatchQueue.main.async { [weak self] in
            guard let self, self.projector.revision == revision else { return }
            if self.intent == cancellationIntent, self.pendingSource == nil { self.isProjecting = false }
            self.projector.clearProjection(); self.source = nil; self.windowOpened = false
        }
    }
    func toggleBlank() {
        guard windowOpened else { return }
        projector.toggleBlank()
        for service in altViewServices.values { service.setBlanked(projector.isBlanked) }
    }
    func shutdown() {
        cancelPreparation(); preferenceTask?.cancel(); repositionTask?.cancel()
        for service in altViewServices.values { service.stop(); service.disconnect() }
        for output in Array(nativeOutputs.values) { closeNativeOutput(output.id) }
        deferClearCommittedProjection()
        discovery.shutdown(); projectionDisplays.closeIdentification()
        if let displayObservation { projectionDisplays.removeObserver(displayObservation) }
        displayObservation = nil; subscriptions.removeAll(); remoteSubscriptions.removeAll()
    }
}

extension MainWorkspaceController {
    func closeProjector() { liveProjection.closeProjector() }
    @objc func dismissProjectionMessage(_ sender: Any?) { liveProjection.dismissMessage() }
    @objc func stopProjection(_ sender: Any?) { closeProjector() }
    @objc func toggleBlank(_ sender: Any?) { liveProjection.toggleBlank() }
    @objc func projectSelectedPassage(_ sender: Any?) {
        if let reference = verses.selectedReference ?? navigation.refreshReference { activateVerse(reference) }
    }
    @objc func manageOutputs(_ sender: Any?) {
        NSApplication.shared.sendAction(#selector(AppDelegate.showManageOutputs(_:)), to: nil, from: sender)
    }
    @objc func showPreview(_ sender: Any?) {
        guard windowOpened || liveProjection.hasNativeWindows else { return }
        if preview.isShown { preview.performClose(sender); return }
        preview.behavior = .transient
        preview.contentViewController = NSHostingController(rootView: ProjectionPreview(outputs: liveProjection.outputs, displays: liveProjection.projectionDisplays).environmentObject(projector))
        preview.show(relativeTo: previewButton.bounds, of: previewButton, preferredEdge: .maxY)
    }
}

private struct ProjectionPreview: View {
    @ObservedObject var outputs: OutputConfigurationStore
    @ObservedObject var displays: ProjectionDisplayManager
    @State private var selected: UUID?
    var body: some View {
        let native = outputs.destinations.filter { $0.native != nil }
        let destination = native.first { $0.id == selected } ?? native.first
        let profile = destination?.native.flatMap { outputs.profile($0.profileID) } ?? .audience
        let size = destination?.native?.monitor.flatMap { displays.resolve($0)?.frame.size } ?? CGSize(width: 1920, height: 1080)
        let scale = min(520 / max(1, size.width), 320 / max(1, size.height))
        VStack(alignment: .leading, spacing: 10) {
            if !native.isEmpty {
                Picker("Output", selection: Binding(get: { destination?.id }, set: { selected = $0 })) {
                    ForEach(native) { Text($0.name).tag(Optional($0.id)) }
                }.pickerStyle(.menu)
            }
            ProjectorView(profile: profile).frame(width: size.width, height: size.height)
                .background(.black).scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading).clipped()
            Text("Committed scripture · \(profile.name)").font(.caption).foregroundStyle(.secondary)
        }.padding(12)
    }
}
