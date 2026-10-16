import AppKit
import Network

private actor BenchmarkPairings: AltViewPairingStoring {
    func read(account: String) -> AltViewPairing? { nil }
    func save(_ pairing: AltViewPairing, account: String) {}
}
private final class BenchmarkSender: AltViewSending, @unchecked Sendable {
    var callback: (@Sendable (AltViewSenderStatus) -> Void)?
    var connectionID: UUID?
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID) { self.connectionID = connectionID }
    func disconnect() { connectionID = nil }
    func submit(_ submission: AltViewSubmission) {
        precondition(submission.content == nil && submission.intent == nil, "Settings navigation must not publish")
    }
}

extension NativeWorkspaceReview {
    /// Same main-thread actions before/after, including queued UI updates,
    /// AppKit constraints, intrinsic text sizes, layout and window display.
    @MainActor static func benchmarkSettings(output: URL) async throws {
        let suite = "ViewTheWord.SettingsBenchmark.\(UUID())", sender = BenchmarkSender()
        let defaults = UserDefaults(suiteName: suite)!
        let monitors = (1...4).map { index in
            ProjectionMonitor(id: UInt32(index), identity: "\(String(repeating: String(index), count: 8))-1111-1111-1111-111111111111",
                              name: "Benchmark TV \(index)", frame: CGRect(x: -10000, y: -10000, width: 1920, height: 1080))
        }
        let displays = ProjectionDisplayManager(defaults: defaults, displays: { monitors })
        let library = BibleLibrary(preloadedURLs: [])
        let live = LiveProjectionController(library: library, defaults: defaults, projectionDisplays: displays,
            altViewServiceFactory: { assignment, discovery in
                AltViewProjectionService(destination: assignment.receiver, template: assignment.template,
                    store: BenchmarkPairings(), discovery: discovery) { sender.callback = $0; return sender }
            })
        live.nativeWindowFactory = { _, _, _ in preconditionFailure("Settings navigation must not open output") }
        let nativeIDs = [live.outputs.destinations[0].id, live.outputs.addNative(), live.outputs.addNative()]
        for (index, id) in nativeIDs.enumerated() {
            var destination = live.outputs.destination(id)!
            destination.enabled = false
            destination.assignment = .native(.init(monitor: monitors[index].target, profileID: live.outputs.profiles[index].id))
            precondition(live.outputs.update(destination) == nil)
        }
        let remoteID = live.outputs.addAltView()
        live.refreshPreferences()
        let settings = SettingsWindowController(library: library, liveProjection: live), window = settings.window!
        let manager = settings.settings.outputs
        manager.discoveryEnabled = false
        settings.showWindow(nil)
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { settings.close(); live.shutdown(); defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<20 { await Task.yield() }
        func layout() {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        layout()
        let original = live.outputs.configuration, revision = live.projector.revision
        var results: [[String: Any]] = []
        func measure(_ name: String, _ action: (Int) -> Void) async {
            var samples: [Double] = []
            for iteration in 0..<88 {
                let start = DispatchTime.now().uptimeNanoseconds
                action(iteration)
                // Drain coalesced objectWillChange tasks as part of the cost.
                for _ in 0..<12 { await Task.yield() }
                layout()
                let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                if iteration >= 8 { samples.append(milliseconds) }
            }
            samples.sort()
            let median = samples[samples.count / 2], p95 = samples[Int(Double(samples.count) * 0.95)]
            results.append(["action": name, "samples": samples.count, "median_ms": median, "p95_ms": p95])
            FileHandle.standardOutput.write(Data(String(format: "%@: median %.3f ms, p95 %.3f ms\n", name, median, p95).utf8))
        }
        await measure("Outputs / Profiles") { index in
            manager.section.selectedSegment = index % 2
            manager.section.sendAction(manager.section.action, to: manager.section.target)
        }
        manager.selectProfile(live.outputs.profiles[0].id); layout()
        await measure("Profile rows") { index in manager.table.selectRowIndexes(IndexSet(integer: index % 3), byExtendingSelection: false) }
        manager.selectDestination(nativeIDs[0]); layout()
        await measure("Native output rows") { index in manager.table.selectRowIndexes(IndexSet(integer: index % 3), byExtendingSelection: false) }
        await measure("Native status unchanged") { _ in live.objectWillChange.send() }
        await measure("Native / AltView rows") { index in manager.table.selectRowIndexes(IndexSet(integer: index % 2 == 0 ? 3 : 0), byExtendingSelection: false) }
        manager.selectDestination(remoteID)
        precondition(live.connectAltView(remoteID, to: .init(name: "Benchmark", host: "127.0.0.1", port: 49721), code: "ABCD2345") == nil)
        for _ in 0..<100 where sender.connectionID == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        let connectionID = sender.connectionID!, receiverID = UUID()
        func status(_ index: Int) {
            sender.callback?(.init(connectionID: connectionID, connected: true, receiverID: receiverID,
                                   message: "Connected · benchmark \(index % 2)"))
        }
        status(0)
        for _ in 0..<20 { await Task.yield() }
        // Connect Only changes its destination during setup, outside navigation.
        let connectedConfiguration = live.outputs.configuration
        await measure("AltView status visible", status)
        manager.selectProfile(live.outputs.profiles[0].id); layout()
        await measure("AltView status with Profiles", status)
        manager.selectDestination(remoteID)
        settings.settings.selectedTabViewItemIndex = 1; layout()
        await measure("AltView status with Library", status)
        settings.close()
        await measure("AltView status closed Settings", status)
        precondition(live.outputs.configuration == connectedConfiguration && live.projector.revision == revision)
        precondition(live.source == nil && live.nativeOutputs.isEmpty && !live.windowOpened)
        precondition(original.profiles == live.outputs.configuration.profiles)
        let labelIndex = CommandLine.arguments.firstIndex(of: "--benchmark-label")
        let label = labelIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil } ?? "latest"
        let data = try JSONSerialization.data(withJSONObject: ["label": label, "iterations": 80, "includes_layout_and_display": true, "results": results], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("settings-benchmark-\(label).json"))
    }
}
