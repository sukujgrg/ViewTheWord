import AppKit
import Network
import XCTest
@testable import ViewTheWordCore

private actor MemoryAltViewPairings: AltViewPairingStoring {
    var values: [String: AltViewPairing] = [:]
    let failsSaving: Bool
    init(failsSaving: Bool = false) { self.failsSaving = failsSaving }
    func read(account: String) -> AltViewPairing? { values[account] }
    func save(_ pairing: AltViewPairing, account: String) throws {
        if failsSaving { throw NSError(domain: "Keychain fixture", code: 1) }
        values[account] = pairing
    }
}

/// Test calls and callbacks are delivered on the main actor, like the real client.
private final class RecordingAltViewSender: AltViewSending, @unchecked Sendable {
    var connections: [(UUID, UUID?)] = []
    var submissions: [AltViewSubmission] = []
    var disconnects = 0
    var callback: (@Sendable (AltViewSenderStatus) -> Void)?
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID) {
        connections.append((connectionID, expectedReceiverID))
    }
    func submit(_ submission: AltViewSubmission) { submissions.append(submission) }
    func disconnect() { disconnects += 1 }
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
    func testStatusSeparatesLatestAcceptanceAndReadiness() async throws {
        let defaults = UserDefaults(suiteName: "AltViewTests.\(UUID())")!
        let client = RecordingAltViewSender()
        let service = AltViewProjectionService(defaults: defaults, store: MemoryAltViewPairings()) { callback in client.callback = callback; return client }
        defer { service.disconnect() }
        service.connect(to: .init(name: "Test", host: "127.0.0.1"), code: "ABCD2345")
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
        let live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [prepared.sources.primary, prepared.sources.secondary!]), defaults: defaults, altView: service)
        live.projectorWindowFactory = { _ in nil }
        defer { live.shutdown() }
        let tab = UUID()
        live.publishRow(prepared, from: tab)
        XCTAssertTrue(client.submissions.isEmpty, "Off means no networking")
        service.connect(to: .init(name: "Test", host: "127.0.0.1"), code: "ABCD2345")
        try await eventually { !client.connections.isEmpty }
        XCTAssertTrue(client.submissions.isEmpty, "Connect Only never sends already-live content")
        live.toggleBlank()
        XCTAssertTrue(client.submissions.isEmpty, "Blank after Connect Only must not acquire output")
        live.publishRow(prepared, from: tab)
        let first = try XCTUnwrap(client.submissions.last)
        XCTAssertEqual(first.content?.body, "Primary text")
        XCTAssertEqual(first.content?.footer, "English · NIV")
        XCTAssertEqual(first.content?.visible, true)
        live.toggleBlank()
        XCTAssertEqual(client.submissions.last?.content?.visible, false)
        XCTAssertEqual(client.submissions.last?.intent, first.intent)
        let reader = VerseTargetModel()
        let token = live.beginIntent(from: tab, sources: prepared.sources, using: reader)
        live.publish(projection(primary: nil), intent: token, preserveBlanking: true)
        XCTAssertEqual(client.submissions.last?.content?.body, "Secondary text")
        XCTAssertEqual(client.submissions.last?.content?.footer, "English · NLT")
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
        service.connect(to: .init(name: "A", host: "a.local"), code: "ABCD2345")
        service.disconnect()
        await Task.yield()
        XCTAssertTrue(client.connections.isEmpty)
        service.connect(to: .init(name: "B", host: "b.local"), code: "ABCD2345")
        try await eventually { client.connections.count == 1 }
        let old = client.connections[0].0
        service.publish(projection(), blanked: false, explicit: true)
        service.connect(to: .init(name: "C", host: "c.local"), code: "ABCD2345")
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
        service.connect(to: .init(name: "A", host: "a.local"), code: "ABCD2345")
        service.publish(projection(primary: "Old"), blanked: false, explicit: true)
        service.publish(projection(primary: "Newest"), blanked: false, explicit: true)
        service.setBlanked(true)
        try await eventually { !client.submissions.isEmpty }
        XCTAssertEqual(client.submissions.last?.content?.body, "Newest")
        XCTAssertEqual(client.submissions.last?.content?.visible, false)
        service.connect(to: .init(name: "B", host: "b.local"), code: "ABCD2345")
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
        let destination = AltViewDestination(name: "Test", host: "receiver.local")
        let receiverID = UUID()
        let firstClient = RecordingAltViewSender()
        let first = AltViewProjectionService(defaults: defaults, store: store) { callback in firstClient.callback = callback; return firstClient }
        defer { first.disconnect() }
        first.connect(to: destination, code: "ABCD2345")
        try await eventually { firstClient.connections.count == 1 }
        firstClient.callback?(.init(connectionID: firstClient.connections[0].0, connected: true, receiverID: receiverID))
        for _ in 0..<100 {
            if await store.read(account: destination.account) != nil { break }
            await Task.yield()
        }
        let saved = await store.read(account: destination.account)
        XCTAssertEqual(saved?.receiverID, receiverID)
        XCTAssertEqual(saved?.key, Data("ABCD2345".utf8))
        let destinationData = try XCTUnwrap(defaults.data(forKey: AppDefaultsKey.altViewDestination))
        XCTAssertEqual(try JSONDecoder().decode(AltViewDestination.self, from: destinationData), destination)
        XCTAssertFalse(String(decoding: destinationData, as: UTF8.self).contains("ABCD2345"))
        let secondClient = RecordingAltViewSender()
        let second = AltViewProjectionService(defaults: defaults, store: store) { callback in secondClient.callback = callback; return secondClient }
        defer { second.disconnect() }
        second.connect(to: destination, code: "")
        try await eventually { secondClient.connections.count == 1 }
        XCTAssertEqual(secondClient.connections.last?.1, receiverID)
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
        let destination = AltViewDestination(name: "Test", host: "receiver.local")
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

}
