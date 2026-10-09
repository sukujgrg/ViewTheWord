import AppKit
import Network
import Security
import XCTest
@testable import ViewTheWordCore

private actor MemoryAltViewPairings: AltViewPairingStoring {
    var values: [String: AltViewPairing] = [:]
    let failsSaving: Bool
    let failsReading: Bool
    init(failsSaving: Bool = false, failsReading: Bool = false) {
        self.failsSaving = failsSaving; self.failsReading = failsReading
    }
    func read(account: String) throws -> AltViewPairing? {
        if failsReading { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)) }
        return values[account]
    }
    func save(_ pairing: AltViewPairing, account: String) throws {
        if failsSaving { throw NSError(domain: "Keychain fixture", code: 1) }
        values[account] = pairing
    }
}

private actor SuspendedAltViewPairings: AltViewPairingStoring {
    var continuation: CheckedContinuation<AltViewPairing?, Never>?
    var isReading: Bool { continuation != nil }
    func read(account: String) async -> AltViewPairing? {
        await withCheckedContinuation { continuation = $0 }
    }
    func save(_ pairing: AltViewPairing, account: String) {}
    func finish(_ pairing: AltViewPairing) { continuation?.resume(returning: pairing); continuation = nil }
}

/// Test calls and callbacks are delivered on the main actor, like the real client.
private final class RecordingAltViewSender: AltViewSending, @unchecked Sendable {
    var connections: [(UUID, UUID?)] = []
    var endpoints: [NWEndpoint] = []
    var endpointUpdates: [(NWEndpoint, UUID)] = []
    var submissions: [AltViewSubmission] = []
    var disconnects = 0
    var callback: (@Sendable (AltViewSenderStatus) -> Void)?
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID) {
        connections.append((connectionID, expectedReceiverID))
        endpoints.append(endpoint)
    }
    func updateEndpoint(_ endpoint: NWEndpoint, connectionID: UUID) { endpointUpdates.append((endpoint, connectionID)) }
    func submit(_ submission: AltViewSubmission) { submissions.append(submission) }
    func disconnect() { disconnects += 1 }
}

private final class RecordingAltViewDiscovery: AltViewDiscovering {
    var starts = 0
    var stops = 0
    var callback: (([AltViewDiscoveredReceiver], String?) -> Void)?
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

final class AltViewProtocolTests: XCTestCase {
    func testFeedbackStaysBoundedAndYieldsToSnapshotsAndControls() throws {
        var outbox = AltViewMessageOutbox()
        let lease = UUID()
        for revision in 1...10_000 {
            try outbox.enqueue(AltViewWireMessage(kind: .feedback, lease: lease, revision: UInt64(revision), outputReadiness: .ready))
        }
        try outbox.enqueue(AltViewWireMessage(kind: .state, revision: 1))
        try outbox.enqueue(AltViewWireMessage(kind: .ownership))
        XCTAssertEqual(outbox.count, 3)
        XCTAssertEqual(outbox.next()?.kind, .ownership)
        XCTAssertEqual(outbox.next()?.kind, .state)
        let feedback = try XCTUnwrap(outbox.next())
        XCTAssertEqual(feedback.revision, 10_000)
        var decoder = AltViewFrameDecoder()
        XCTAssertEqual(try decoder.append(AltViewFrameCodec.encode(feedback)), [feedback])
        XCTAssertNil(outbox.next())
    }
    func testAcknowledgementsAreLeaseScopedAndTimeoutNeverStopsNewSnapshots() {
        let lease = UUID()
        var feedback = AltViewDeliveryFeedback()
        feedback.sent(1, now: 0)
        feedback.sent(2, now: 1)
        feedback.receive(AltViewWireMessage(kind: .feedback, lease: UUID(), revision: 2, outputReadiness: .closed), lease: lease, now: 2)
        XCTAssertEqual(feedback.acceptedRevision, 0)
        XCTAssertEqual(feedback.output, .closed)
        feedback.receive(AltViewWireMessage(kind: .feedback, lease: lease, revision: 3, outputReadiness: .ready), lease: lease, now: 3)
        XCTAssertEqual(feedback.acceptedRevision, 0, "A future revision cannot acknowledge unsent text")
        XCTAssertTrue(feedback.checkTimeout(now: 6))
        XCTAssertTrue(feedback.overdue)
        feedback.sent(10, now: 7)
        XCTAssertEqual(feedback.sentRevision, 10, "Feedback never gates new snapshots")
        feedback.receive(AltViewWireMessage(kind: .feedback, lease: lease, revision: 10, outputReadiness: .ready), lease: lease, now: 8)
        XCTAssertTrue(feedback.accepted)
        XCTAssertFalse(feedback.overdue)
        feedback.receive(AltViewWireMessage(kind: .feedback, lease: lease, revision: 1, outputReadiness: .preview), lease: lease, now: 9)
        XCTAssertEqual(feedback.acceptedRevision, 10)
        feedback.resetSnapshot()
        XCTAssertFalse(feedback.accepted)
        XCTAssertEqual(feedback.output, .preview, "Release keeps display information")
        XCTAssertFalse(feedback.checkTimeout(now: 100))
    }


    func testFragmentedAndCombinedFramesPreserveUnicodeAndBlankText() throws {
        let content = AltViewDisplayContent(title: "John 3:16", body: "മലയാളം · שלום\n\"Text\"", footer: "English · UKJV", visible: false)
        let message = AltViewWireMessage(kind: .state, lease: UUID(), revision: UInt64.max, content: content)
        let frame = try AltViewFrameCodec.encode(message)
        var decoder = AltViewFrameDecoder()
        var decoded: [AltViewWireMessage] = []
        for byte in frame { decoded += try decoder.append(Data([byte])) }
        XCTAssertEqual(decoded, [message])
        XCTAssertEqual(try decoder.append(frame + frame), [message, message])
        XCTAssertThrowsError(try decoder.append(Data([0, 1, 0, 1])))
        var emptyDecoder = AltViewFrameDecoder()
        XCTAssertThrowsError(try emptyDecoder.append(Data([0, 0, 0, 0])))
    }
    func testPairingBoundsAndInvalidReceiverFields() throws {
        XCTAssertEqual(AltViewPairingKey.parse(" abcd-2345 \n"), Data("ABCD2345".utf8))
        for invalid in ["ABCD2340", "ABCD2341", "ABC2345", String(repeating: "A", count: 64), "ＡBCD2345"] {
            XCTAssertNil(AltViewPairingKey.parse(invalid))
        }
        XCTAssertFalse(AltViewDisplayContent(body: String(repeating: "മ", count: 8_001)).isValid)
        let escaped = AltViewDisplayContent(body: String(repeating: "\u{01}", count: 24_000))
        XCTAssertTrue(escaped.isValid)
        XCTAssertThrowsError(try AltViewFrameCodec.encode(AltViewWireMessage(kind: .state, content: escaped)))
        XCTAssertFalse(AltViewWireMessage(kind: .welcome).isValidReceiverMessage)
        XCTAssertFalse(AltViewWireMessage(kind: .ownership, ownerID: UUID()).isValidReceiverMessage)
        XCTAssertFalse(AltViewWireMessage(version: 1, kind: .heartbeat).isValidReceiverMessage)
        XCTAssertFalse(AltViewWireMessage(kind: .granted).isValidReceiverMessage)
        XCTAssertTrue(AltViewWireMessage(kind: .ownership).isValidReceiverMessage)
        XCTAssertThrowsError(try JSONDecoder().decode(AltViewWireMessage.self, from: Data(#"{"version":1,"kind":"unknown"}"#.utf8)))
    }
    func testBoundedMailboxAndOutboxKeepLatestSnapshot() throws {
        let queue = DispatchQueue(label: "altview.mailbox.test")
        queue.suspend()
        let received = expectation(description: "one newest submission")
        received.assertForOverFulfill = true
        let mailbox = AltViewSnapshotMailbox<Int>(queue: queue) { value in
            XCTAssertEqual(value, 1_999); received.fulfill()
        }
        for value in 0..<2_000 { mailbox.offer(value) }
        queue.resume()
        wait(for: [received], timeout: 2)
        var outbox = AltViewMessageOutbox()
        for i in 0..<2_000 { try outbox.enqueue(AltViewWireMessage(kind: .state, revision: UInt64(i))) }
        for _ in 0..<2_000 { try outbox.enqueue(AltViewWireMessage(kind: .heartbeat)) }
        XCTAssertEqual(outbox.count, 2)
        XCTAssertEqual(outbox.next()?.revision, 1_999)
        for _ in 0..<16 { try outbox.enqueue(AltViewWireMessage(kind: .take)) }
        XCTAssertThrowsError(try outbox.enqueue(AltViewWireMessage(kind: .take)))
    }
}

@MainActor
final class AltViewProjectionTests: XCTestCase {
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Condition did not settle")
    }
    private func projection(primary: String? = "Primary text", secondary: String? = "Secondary text") -> PreparedProjection {
        let reference = VerseReference(book: "John", chapter: 3, verse: 16)!
        let sources = BibleSources(primary: URL(fileURLWithPath: "/ENG_NIV.bible"), secondary: URL(fileURLWithPath: "/ENG_NLT.bible"), revision: 1)
        return PreparedProjection(pair: TranslationPair(reference: reference,
            primary: primary.map { AVerse(reference: reference, verse: $0) },
            secondary: secondary.map { AVerse(reference: reference, verse: $0) }), sources: sources, owner: .verseRowSelection(reference))!
    }
    func testTemplatePickerUsesReceiverIDsAndKeepsChangesPrivateUntilProjection() async throws {
        _ = NSApplication.shared
        let suite = "AltViewTemplates.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = RecordingAltViewSender()
        let service = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings()) {
            callback in client.callback = callback; return client
        }
        defer { service.disconnect() }
        let pane = AltViewSettingsController(service: service)
        pane.discoveryEnabled = false
        pane.loadViewIfNeeded()
        XCTAssertEqual(service.selectedTemplate, .scripture)
        XCTAssertFalse(pane.templatePicker.isEnabled)
        service.connect(to: .init(name: "Test", host: "127.0.0.1", port: 54321), code: "ABCD2345")
        try await eventually { !client.connections.isEmpty }
        let future = AltViewContentTemplate(rawValue: "future.layout")
        let entries = [AltViewTemplateDescriptor(id: .scripture, name: "Same label"), .init(id: future, name: "Same label")]
        var status = AltViewSenderStatus(connectionID: client.connections[0].0, connected: true,
            templateCapabilities: .init(templates: entries, policy: .sender))
        client.callback?(status)
        try await eventually { pane.templatePicker.numberOfItems == 3 && pane.templatePicker.isEnabled }
        XCTAssertEqual(pane.templatePicker.selectedItem?.representedObject as? String, "scripture")
        XCTAssertEqual(pane.templatePicker.itemTitles, ["Receiver’s layout", "Same label", "Same label"])
        XCTAssertTrue(client.submissions.isEmpty, "Discovery and Connect Only cannot publish")
        service.publish(projection(), blanked: false, explicit: true)
        XCTAssertEqual(client.submissions.last?.content?.template, .scripture)
        pane.templatePicker.selectItem(at: 2)
        NSApp.sendAction(pane.templatePicker.action!, to: pane.templatePicker.target, from: pane.templatePicker)
        XCTAssertEqual(service.selectedTemplate, future)
        XCTAssertEqual(client.submissions.count, 1, "Choosing a template stays private")
        service.setBlanked(true)
        service.publish(projection(primary: nil), blanked: true, explicit: false)
        XCTAssertEqual(client.submissions.last?.content?.template, .scripture, "Blank/translation refresh preserve the published choice")
        service.publish(projection(), blanked: false, explicit: true)
        XCTAssertEqual(client.submissions.last?.content?.template, future)
        let count = client.submissions.count
        let menuItem = pane.templatePicker.item(at: 2)
        let receiverItem = pane.receiverPicker.item(at: 0)
        status.templateCapabilities.policy = .custom
        client.callback?(status)
        try await eventually { pane.statusLabel.stringValue.contains("overrides") }
        XCTAssertTrue(pane.templatePicker.item(at: 2) === menuItem, "Policy/acknowledgement updates preserve open menu items")
        XCTAssertTrue(pane.receiverPicker.item(at: 0) === receiverItem, "Status updates preserve the receiver menu too")
        status.templateCapabilities.templates = [entries[0]]
        client.callback?(status)
        try await eventually { pane.templatePicker.selectedItem?.title.contains("Unavailable") == true }
        XCTAssertFalse(pane.templatePicker.selectedItem!.isEnabled)
        XCTAssertEqual(service.selectedTemplate, future)
        XCTAssertTrue(pane.templateHint.stringValue.contains("unavailable"))
        XCTAssertEqual(client.submissions.count, count)
        status.templateCapabilities = .init()
        client.callback?(status)
        try await eventually { pane.templateHint.stringValue.contains("does not advertise") }
        let restored = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings()) { _ in RecordingAltViewSender() }
        XCTAssertEqual(restored.selectedTemplate, future, "Unavailable choices survive relaunch")
        pane.templatePicker.selectItem(at: 0)
        NSApp.sendAction(pane.templatePicker.action!, to: pane.templatePicker.target, from: pane.templatePicker)
        XCTAssertNil(service.selectedTemplate)
        XCTAssertEqual(client.submissions.count, count)
        service.publish(projection(), blanked: false, explicit: true)
        XCTAssertNil(client.submissions.last?.content?.template)
        let receiverLayout = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings()) { _ in RecordingAltViewSender() }
        XCTAssertNil(receiverLayout.selectedTemplate, "Receiver layout must not reset to Scripture on relaunch")
        service.disconnect()
        try await eventually { !pane.templatePicker.isEnabled }
        XCTAssertNil(service.status.templateCapabilities.templates)
    }

    func testStatusSeparatesLatestAcceptanceAndReadiness() async throws {
        let defaults = UserDefaults(suiteName: "AltViewTests.\(UUID())")!
        let client = RecordingAltViewSender()
        let service = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings()) { callback in client.callback = callback; return client }
        defer { service.disconnect() }
        service.connect(to: .init(name: "Test", host: "127.0.0.1", port: 54321), code: "ABCD2345")
        try await eventually { !client.connections.isEmpty }
        service.publish(projection(), blanked: false, explicit: true)
        let submission = try XCTUnwrap(client.submissions.last)
        let lease = UUID()
        var feedback = AltViewDeliveryFeedback()
        feedback.sent(1, now: 0)
        feedback.receive(.init(kind: .feedback, lease: lease, revision: 1, outputReadiness: .ready), lease: lease, now: 1)
        var status = AltViewSenderStatus(connectionID: service.status.connectionID, connected: true, ownsOutput: true,
                                        feedback: feedback, submissionID: submission.id)
        client.callback?(status)
        XCTAssertEqual(service.summary, "AltView · snapshot accepted")
        service.setBlanked(true)
        XCTAssertEqual(service.summary, "AltView · awaiting acknowledgement", "The previous verse's ack cannot confirm a new blank")
        XCTAssertFalse(service.detail.contains("Latest snapshot accepted"))
        status.submissionID = client.submissions.last?.id
        status.feedback.sent(2, now: 2)
        client.callback?(status)
        XCTAssertEqual(service.summary, "AltView · awaiting acknowledgement")
        status.feedback.receive(.init(kind: .feedback, lease: lease, revision: 2, outputReadiness: .closed), lease: lease, now: 3)
        client.callback?(status)
        XCTAssertEqual(service.summary, "AltView · output window closed")
        XCTAssertTrue(service.detail.contains("Latest snapshot accepted"))

    }
    func testProjectionBlankRefreshFallbackAndStopAreSharedAndNonblocking() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "AltViewTests.\(UUID())")!
        let client = RecordingAltViewSender()
        let service = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings()) { callback in client.callback = callback; return client }
        let prepared = projection()
        let live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [prepared.sources.primary, prepared.sources.secondary!]), defaults: defaults, altView: service, projectionDisplays: selectedTestProjectionDisplays())
        live.projectorWindowFactory = { _ in nil }
        defer { live.shutdown() }
        let tab = UUID()
        live.publishRow(prepared, from: tab)
        XCTAssertTrue(client.submissions.isEmpty, "Off means no networking")
        service.connect(to: .init(name: "Test", host: "127.0.0.1", port: 54321), code: "ABCD2345")
        try await eventually { !client.connections.isEmpty }
        XCTAssertTrue(client.submissions.isEmpty, "Connect Only never sends already-live content")
        live.toggleBlank()
        XCTAssertTrue(client.submissions.isEmpty, "Blank after Connect Only must not acquire output")
        live.publishRow(prepared, from: tab)
        let first = try XCTUnwrap(client.submissions.last)
        XCTAssertEqual(first.content?.body, "Primary text")
        XCTAssertEqual(first.content?.footer, "English · NIV")
        XCTAssertEqual(first.content?.confidence, .init(title: "John 3:16", body: "Primary text", footer: "English · NIV"))
        XCTAssertEqual(first.content?.visible, true)
        live.toggleBlank()
        XCTAssertEqual(client.submissions.last?.content?.visible, false)
        XCTAssertEqual(client.submissions.last?.content?.confidence, first.content?.confidence)
        XCTAssertEqual(client.submissions.last?.intent, first.intent)
        let reader = VerseTargetModel()
        let token = live.beginIntent(from: tab, sources: prepared.sources, using: reader)
        live.publish(projection(primary: nil), intent: token, preserveBlanking: true)
        XCTAssertEqual(client.submissions.last?.content?.body, "Secondary text")
        XCTAssertEqual(client.submissions.last?.content?.footer, "English · NLT")
        XCTAssertEqual(client.submissions.last?.content?.confidence, .init(title: "John 3:16", body: "Secondary text", footer: "English · NLT"))
        XCTAssertEqual(client.submissions.last?.content?.visible, false)
        XCTAssertEqual(client.submissions.last?.intent, first.intent, "Translation refresh cannot take ownership")
        let count = client.submissions.count
        live.detachTab(tab)
        XCTAssertEqual(client.submissions.count, count, "Closing the source tab preserves remote output")
        let canceled = live.beginIntent(from: UUID(), sources: prepared.sources, using: reader)
        live.closeProjector()
        live.publish(prepared, intent: canceled)
        XCTAssertNil(client.submissions.last?.content, "Stop cancels late preparation and releases remote output")
        // New publication wins over the previous window's deferred close cleanup.
        live.publishRow(prepared, from: UUID())
        await Task.yield()
        XCTAssertNotNil(client.submissions.last?.content)
        XCTAssertNotNil(live.projector.projectionOwner)
    }
    func testCancelSwitchAndLateStatusesCannotPublishOrSaveOldPairing() async throws {
        let defaults = UserDefaults(suiteName: "AltViewTests.\(UUID())")!
        let client = RecordingAltViewSender()
        let service = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings()) { callback in client.callback = callback; return client }
        defer { service.disconnect() }
        service.connect(to: .init(name: "A", host: "a.local", port: 54321), code: "ABCD2345")
        service.disconnect()
        await Task.yield()
        XCTAssertTrue(client.connections.isEmpty)
        service.connect(to: .init(name: "B", host: "b.local", port: 54321), code: "ABCD2345")
        try await eventually { client.connections.count == 1 }
        let old = client.connections[0].0
        service.publish(projection(), blanked: false, explicit: true)
        service.connect(to: .init(name: "C", host: "c.local", port: 54321), code: "ABCD2345")
        try await eventually { client.connections.count == 2 }
        let current = service.status.connectionID
        client.callback?(AltViewSenderStatus(connectionID: old, connected: true, ownsOutput: true, receiverID: UUID(), message: "Old"))
        XCTAssertEqual(service.status.connectionID, current)
        XCTAssertFalse(service.status.connected)
        XCTAssertNil(defaults.data(forKey: AppDefaultsKey.altViewDestination))
        XCTAssertEqual(client.submissions.count, 1, "Changing destinations must not resend live content")
    }
    func testProjectionDuringPairingUsesLatestAndStopCancelsPendingPublication() async throws {
        let client = RecordingAltViewSender()
        let service = AltViewProjectionService(store: MemoryAltViewPairings()) { callback in client.callback = callback; return client }
        defer { service.disconnect() }
        service.connect(to: .init(name: "A", host: "a.local", port: 54321), code: "ABCD2345")
        service.publish(projection(primary: "Old"), blanked: false, explicit: true)
        service.publish(projection(primary: "Newest"), blanked: false, explicit: true)
        service.setBlanked(true)
        try await eventually { !client.submissions.isEmpty }
        XCTAssertEqual(client.submissions.last?.content?.body, "Newest")
        XCTAssertEqual(client.submissions.last?.content?.visible, false)
        service.connect(to: .init(name: "B", host: "b.local", port: 54321), code: "ABCD2345")
        let count = client.submissions.count
        service.publish(projection(), blanked: false, explicit: true)
        service.stop()
        try await eventually { client.connections.count == 2 }
        XCTAssertEqual(client.submissions.count, count)
    }
    func testSuccessfulPairingPersistsIdentityWithoutPlaintextDefaultsAndExplicitCodeReplacesPin() async throws {
        let suite = "AltViewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MemoryAltViewPairings()
        let destination = AltViewDestination(name: "Test", host: "receiver.local", port: 54321)
        let receiverID = UUID()
        let firstClient = RecordingAltViewSender()
        let first = AltViewProjectionService(defaults: defaults, store: store) { callback in firstClient.callback = callback; return firstClient }
        defer { first.disconnect() }
        first.connect(to: destination, code: "ABCD2345")
        try await eventually { firstClient.connections.count == 1 }
        firstClient.callback?(.init(connectionID: firstClient.connections[0].0, connected: true, receiverID: receiverID))
        for _ in 0..<100 {
            if try await store.read(account: destination.account) != nil { break }
            await Task.yield()
        }
        let saved = try await store.read(account: destination.account)
        XCTAssertEqual(saved?.receiverID, receiverID)
        XCTAssertEqual(saved?.key, Data("ABCD2345".utf8))
        let destinationData = try XCTUnwrap(defaults.data(forKey: AppDefaultsKey.altViewDestination))
        XCTAssertEqual(try JSONDecoder().decode(AltViewDestination.self, from: destinationData), destination)
        XCTAssertFalse(String(decoding: destinationData, as: UTF8.self).contains("ABCD2345"))
        let secondClient = RecordingAltViewSender()
        let second = AltViewProjectionService(defaults: defaults, store: store) { callback in secondClient.callback = callback; return secondClient }
        defer { second.disconnect() }
        second.restoreConnection()
        second.restoreConnection()
        try await eventually { secondClient.connections.count == 1 }
        XCTAssertEqual(secondClient.connections.last?.1, receiverID)
        XCTAssertTrue(secondClient.submissions.isEmpty, "Automatic connection must not claim or publish output")
        second.disconnect()
        second.restoreConnection()
        await Task.yield()
        XCTAssertEqual(secondClient.connections.count, 1, "Disconnect lasts for the rest of this app session")
        second.connect(to: destination, code: "ABCD2346")
        try await eventually { secondClient.connections.count == 2 }
        XCTAssertNil(secondClient.connections.last?.1, "Entering a new code explicitly permits a new receiver identity")
    }
    func testKeychainSaveFailureRetainsSessionPairingAndShowsNotice() async throws {
        let suite = "AltViewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = RecordingAltViewSender()
        let service = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings(failsSaving: true)) { callback in client.callback = callback; return client }
        defer { service.disconnect() }
        let destination = AltViewDestination(name: "Test", host: "receiver.local", port: 54321)
        let receiverID = UUID()
        service.connect(to: destination, code: "ABCD2345")
        try await eventually { client.connections.count == 1 }
        client.callback?(.init(connectionID: client.connections[0].0, connected: true, receiverID: receiverID))
        try await eventually { service.pairingNote != nil }
        XCTAssertTrue(service.status.connected)
        XCTAssertTrue(service.pairingNote?.contains("Keychain") == true)
        service.disconnect()
        service.connect(to: destination, code: "")
        try await eventually { client.connections.count == 2 }
        XCTAssertEqual(client.connections.last?.1, receiverID, "A failed save still allows reuse within this session")
    }

    func testStartupReadErrorIsExplainedAndDisconnectIsDisabledUntilConnecting() async throws {
        _ = NSApplication.shared
        let suite = "AltViewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let destination = AltViewDestination(name: "Test", host: "receiver.local", port: 54321)
        defaults.set(try JSONEncoder().encode(destination), forKey: AppDefaultsKey.altViewDestination)
        let client = RecordingAltViewSender()
        let service = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings(failsReading: true)) {
            callback in client.callback = callback; return client
        }
        defer { service.disconnect() }
        let pane = AltViewSettingsController(service: service)
        pane.discoveryEnabled = false
        pane.loadViewIfNeeded()
        XCTAssertFalse(pane.disconnectButton.isEnabled)
        service.restoreConnection()
        try await eventually { service.status.failureReason != nil && pane.connectButton.isEnabled }
        XCTAssertTrue(service.detail.contains("Could not read the saved pairing from Keychain"))
        XCTAssertTrue(client.connections.isEmpty)
        XCTAssertFalse(pane.disconnectButton.isEnabled)
        XCTAssertTrue(pane.statusLabel.stringValue.contains("Keychain"))

        service.connect(to: destination, code: "ABCD2345")
        try await eventually { client.connections.count == 1 && pane.disconnectButton.title == "Cancel" }
        XCTAssertTrue(pane.disconnectButton.isEnabled)
        let id = client.connections[0].0
        client.callback?(.init(connectionID: id, waitingToRetry: true))
        try await eventually { pane.statusBadge.accessibilityValue() as? String == "AltView · Waiting to reconnect" }
        XCTAssertEqual(pane.disconnectButton.title, "Cancel")
        client.callback?(.init(connectionID: id, failureReason: "Pairing rejected"))
        try await eventually { !pane.disconnectButton.isEnabled }
        XCTAssertTrue(pane.connectButton.isEnabled)
        client.callback?(.init(connectionID: id, connected: true))
        try await eventually { pane.disconnectButton.isEnabled && pane.disconnectButton.title == "Disconnect" }
        pane.disconnectButton.performClick(nil)
        XCTAssertFalse(service.isEnabled)
        try await eventually { !pane.disconnectButton.isEnabled }
    }

    func testCancelDuringStartupKeychainReadCannotConnectOrPublishLater() async throws {
        let suite = "AltViewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let destination = AltViewDestination(name: "Test", host: "receiver.local", port: 54321)
        defaults.set(try JSONEncoder().encode(destination), forKey: AppDefaultsKey.altViewDestination)
        let store = SuspendedAltViewPairings()
        let client = RecordingAltViewSender()
        let service = AltViewProjectionService(defaults: defaults, store: store) {
            callback in client.callback = callback; return client
        }
        defer { service.disconnect() }
        service.restoreConnection()
        for _ in 0..<100 {
            if await store.isReading { break }
            await Task.yield()
        }
        let reading = await store.isReading
        XCTAssertTrue(reading)
        service.publish(projection(), blanked: false, explicit: true)
        service.disconnect()
        await store.finish(.init(key: Data("ABCD2345".utf8), receiverID: UUID()))
        await Task.yield()
        XCTAssertTrue(client.connections.isEmpty)
        XCTAssertTrue(client.submissions.isEmpty)
        XCTAssertFalse(service.isEnabled)
    }

    func testStartupWithoutDestinationDoesNotStartNetworking() async {
        let suite = "AltViewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings()) { _ in
            XCTFail("No receiver has ever been connected")
            return RecordingAltViewSender()
        }
        service.restoreConnection()
        await Task.yield()
        XCTAssertFalse(service.isEnabled)
    }

    func testLocalRestoreWaitsForFreshDiscoveryAndCancellationIgnoresLatePortChanges() async throws {
        let suite = "AltViewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let receiverID = UUID()
        func receiver(_ port: UInt16, id: UUID? = nil) -> AltViewDiscoveredReceiver {
            AltViewDiscoveredReceiver(name: "This Mac · Fixture", endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!),
                                      receiverID: id ?? receiverID, isLocal: true)
        }
        let saved = try XCTUnwrap(AltViewDestination(receiver(54321)))
        defaults.set(try JSONEncoder().encode(saved), forKey: AppDefaultsKey.altViewDestination)
        let store = MemoryAltViewPairings()
        try await store.save(.init(key: Data("ABCD2345".utf8), receiverID: receiverID), account: saved.account)
        let client = RecordingAltViewSender(), discovery = RecordingAltViewDiscovery()
        let service = AltViewProjectionService(defaults: defaults, store: store, discoveryFactory: {
            discovery.callback = $0; return discovery
        }) { callback in client.callback = callback; return client }
        defer { service.disconnect() }
        service.restoreConnection()
        service.publish(projection(), blanked: false, explicit: true)
        try await eventually { service.status.waitingToRetry }
        XCTAssertEqual(discovery.starts, 1)
        XCTAssertTrue(client.connections.isEmpty, "A saved dynamic port might now belong to a different receiver")
        discovery.callback?([receiver(54322, id: UUID())], nil)
        XCTAssertTrue(client.connections.isEmpty, "Only the saved receiver UUID may resolve setup")
        discovery.callback?([receiver(54323)], nil)
        try await eventually { client.connections.count == 1 }
        XCTAssertEqual(client.endpoints.last, receiver(54323).endpoint)
        XCTAssertEqual(client.connections.last?.1, receiverID)
        XCTAssertEqual(client.submissions.last?.content?.body, "Primary text", "Discovery preserves an explicit projection queued during setup")
        let intent = client.submissions.last?.intent
        service.stopDiscovery()
        XCTAssertEqual(discovery.stops, 0, "This Mac port tracking continues with Settings closed")
        discovery.callback?([receiver(54324)], nil)
        XCTAssertEqual(client.endpointUpdates.last?.0, receiver(54324).endpoint)
        XCTAssertEqual(client.submissions.last?.intent, intent)
        service.disconnect()
        let updateCount = client.endpointUpdates.count
        discovery.callback?([receiver(54325)], nil)
        XCTAssertEqual(client.endpointUpdates.count, updateCount)
        XCTAssertEqual(client.connections.count, 1)
        XCTAssertEqual(discovery.stops, 1)
    }
    func testDiscoveryRetriesFailuresWithSettingsClosedAndCancelStopsTheRetry() async throws {
        let suite = "AltViewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let discovered = AltViewDiscoveredReceiver(name: "This Mac · Fixture",
            endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: 54321)!), receiverID: UUID(), isLocal: true)
        let destination = try XCTUnwrap(AltViewDestination(discovered))
        let discovery = RecordingAltViewDiscovery(), client = RecordingAltViewSender()
        let service = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings(), discoveryFactory: {
            discovery.callback = $0; return discovery
        }) { callback in client.callback = callback; return client }
        defer { service.disconnect() }
        service.connect(to: destination, code: "ABCD2345")
        try await eventually { service.status.waitingToRetry }
        discovery.callback?([], "Discovery temporarily unavailable")
        for _ in 0..<300 {
            if discovery.starts == 2 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(discovery.starts, 2, "An enabled local sender retries discovery without reopening Settings")
        XCTAssertEqual(discovery.stops, 1)
        discovery.callback?([discovered], nil)
        XCTAssertEqual(client.connections.count, 1)
        discovery.callback?([], "Discovery temporarily unavailable")
        service.disconnect()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(discovery.starts, 2, "Cancel invalidates a scheduled discovery restart")
        XCTAssertEqual(discovery.stops, 2)
    }

}
