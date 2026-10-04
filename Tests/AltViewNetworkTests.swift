import Foundation
import Network
import Security
import XCTest
@testable import ViewTheWordCore

@MainActor
private final class AltViewNetworkObservation {
    var receiver = FixtureReceiverStatus()
    var a = AltViewSenderStatus()
    var b = AltViewSenderStatus()
}

@MainActor
final class AltViewNetworkTests: XCTestCase {
    private let key = Data("ABCD2345".utf8)
    private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Network condition did not complete", file: file, line: line)
        throw NSError(domain: "AltViewTests", code: 1)
    }
    func testTemplateDiscoveryUpdatesObserversAndResolvesEverySnapshotAndReconnect() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        let future = AltViewContentTemplate(rawValue: "future.layout")
        let entries = [AltViewTemplateDescriptor(id: .scripture, name: "Scripture"), .init(id: future, name: "Future")]
        receiver.updateTemplateCapabilities(.init(templates: entries, policy: .sender))
        receiver.start(name: "Templates", key: key, advertise: false)
        let a = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        let b = AltViewSenderClient(name: "B") { value in MainActor.assumeIsolated { state.b = value } }
        defer { a.disconnect(); b.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        let id = UUID(), intent = UUID()
        a.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: id)
        // A publication queued before welcome must resolve against its discovery.
        a.submit(.init(connectionID: id, content: .init(body: "First", template: .scripture), intent: intent))
        b.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: UUID())
        try await eventually { state.a.feedback.accepted && state.b.connected }
        XCTAssertEqual(state.receiver.content.template, .scripture)
        XCTAssertEqual(state.a.templateCapabilities.templates, entries)
        XCTAssertFalse(state.b.ownsOutput)
        let initialRevision = state.receiver.revision
        receiver.updateTemplateCapabilities(.init(templates: entries, policy: .fixed(future)))
        try await eventually { state.a.templateCapabilities.policy == .fixed(future) && state.b.templateCapabilities.policy == .fixed(future) }
        XCTAssertEqual(state.receiver.revision, initialRevision, "Policy broadcasts do not publish")
        a.submit(.init(connectionID: id, content: .init(body: "Hidden", visible: false, template: .scripture), intent: intent))
        try await eventually { state.receiver.content.body == "Hidden" && state.a.feedback.accepted }
        XCTAssertEqual(state.receiver.content.template, .scripture, "An override must not strip a supported request")
        let hiddenRevision = state.receiver.revision
        receiver.updateTemplateCapabilities(.init(templates: [.init(id: future, name: "Future")], policy: .sender))
        try await eventually { state.a.templateCapabilities.templates?.count == 1 && state.b.templateCapabilities.templates?.count == 1 }
        XCTAssertEqual(state.receiver.revision, hiddenRevision, "Catalogue updates do not publish")
        a.submit(.init(connectionID: id, content: .init(body: "Fallback", visible: false, template: .scripture), intent: intent))
        try await eventually { state.receiver.content.body == "Fallback" && state.a.feedback.accepted }
        XCTAssertNil(state.receiver.content.template)
        XCTAssertEqual(state.a.requestedTemplate, .scripture)
        receiver.updateTemplateCapabilities(.init(templates: entries, policy: .custom))
        try await eventually { state.a.templateCapabilities.policy == .custom }
        a.submit(.init(connectionID: id, content: .init(body: "Future ID", visible: false, template: future), intent: intent))
        try await eventually { state.receiver.content.body == "Future ID" && state.a.feedback.accepted }
        XCTAssertEqual(state.receiver.content.template, future)

        receiver.dropConnections(named: "A")
        try await eventually { state.a.waitingToRetry }
        XCTAssertNil(state.a.templateCapabilities.templates, "Disconnect clears discovery")
        receiver.updateTemplateCapabilities(.init()) // Older receiver after reconnect.
        try await eventually { state.a.connected && state.a.feedback.accepted && state.receiver.content.body == "Future ID" }
        XCTAssertNil(state.receiver.content.template, "Restore uses new welcome, not cached capabilities")
        XCTAssertFalse(state.receiver.content.visible)
        XCTAssertEqual(state.a.requestedTemplate, future, "Fallback retains the desired snapshot")
        XCTAssertNil(state.a.templateCapabilities.templates)
        receiver.dropConnections(named: "A")
        try await eventually { state.a.waitingToRetry }
        receiver.updateTemplateCapabilities(.init(templates: entries, policy: .sender))
        try await eventually { state.a.connected && state.a.feedback.accepted && state.receiver.content.template == future }
        XCTAssertFalse(state.receiver.content.visible)
        XCTAssertEqual(state.receiver.revision, 1, "Restoration starts a new revision sequence")
        XCTAssertFalse(state.b.ownsOutput)
        a.disconnect()
        try await eventually { state.a.connectionID == nil }
        XCTAssertNil(state.a.templateCapabilities.templates)
    }

    func testInvalidDiscoveryClosesWelcomeAndFeedbackWithoutRetrying() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.updateTemplateCapabilities(.init(templates: [], policy: .fixed(.scripture)))
        receiver.start(name: "Invalid templates", key: key, advertise: false)
        let client = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        defer { client.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        client.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: UUID())
        try await eventually { state.a.failureReason != nil }
        XCTAssertFalse(state.a.connected)
        XCTAssertFalse(state.a.waitingToRetry)
        XCTAssertNil(state.a.templateCapabilities.templates)
        receiver.updateTemplateCapabilities(.init(templates: [], policy: .sender))
        let id = UUID()
        client.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: id)
        try await eventually { state.a.connected }
        client.submit(.init(connectionID: id, content: .init(body: "Plain text", template: .scripture), intent: UUID()))
        try await eventually { state.a.feedback.accepted }
        XCTAssertNil(state.receiver.content.template, "An empty catalogue offers no templates")
        receiver.updateTemplateCapabilities(.init(templates: [
            .init(id: .scripture, name: "First"), .init(id: .scripture, name: "Duplicate")], policy: .sender))
        try await eventually { state.a.failureReason != nil && state.receiver.ownerName == nil }
        XCTAssertFalse(state.a.connected)
        XCTAssertFalse(state.a.waitingToRetry)
        XCTAssertNil(state.a.templateCapabilities.templates)
    }

    func testRetryBackoffIsBounded() {
        XCTAssertEqual((0...7).map { AltViewSenderClient.reconnectDelay(attempt: $0) }, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(AltViewSenderClient.reconnectDelay(attempt: Int.max), 30)
    }

    func testTLSClosureCanRetryButAuthenticationFailuresCannot() {
        for status in [errSSLClosedGraceful, errSSLClosedAbort, errSSLClosedNoNotify, errSSLNetworkTimeout] {
            XCTAssertTrue(AltViewPeerChannel.isRetryableNetworkError(.tls(status)))
        }
        for status in [errSSLPeerBadRecordMac, errSSLBadRecordMac, errSSLPeerHandshakeFail, errSSLPeerAccessDenied] {
            XCTAssertFalse(AltViewPeerChannel.isRetryableNetworkError(.tls(status)))
        }
        XCTAssertTrue(AltViewPeerChannel.isRetryableNetworkError(.posix(.ECONNRESET)))
    }

    func testReceiverUnavailableAtStartupThenRestartsAndCancelStopsRetries() async throws {
        let state = AltViewNetworkObservation()
        let receiverID = UUID()
        let receiver = FixtureReceiverServer(receiverID: receiverID) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.start(name: "Restart", key: key, advertise: false)
        let client = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        defer { client.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let port = state.receiver.port!
        receiver.stop()
        try await eventually { !state.receiver.listening }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
        let id = UUID()
        client.connect(to: endpoint, key: key, expectedReceiverID: receiverID, connectionID: id)
        try await eventually { state.a.waitingToRetry }
        XCTAssertNil(state.a.failureReason)
        receiver.start(name: "Restart", key: key, port: port, advertise: false)
        try await eventually { state.a.connected }
        XCTAssertNil(state.receiver.ownerName, "Startup reconnection alone cannot claim output")
        client.submit(.init(connectionID: id, content: .init(body: "Before restart", visible: false), intent: UUID()))
        try await eventually { state.a.ownsOutput }
        receiver.stop()
        try await eventually { state.a.waitingToRetry }
        // A new server object models an app restart, retaining only its saved identity and code.
        let restarted = FixtureReceiverServer(receiverID: receiverID) { value in MainActor.assumeIsolated { state.receiver = value } }
        defer { restarted.stop() }
        restarted.start(name: "Restart", key: key, port: port, advertise: false)
        try await eventually { state.a.connected && state.receiver.content.body == "Before restart" }
        XCTAssertFalse(state.receiver.content.visible)
        restarted.stop()
        try await eventually { state.a.waitingToRetry }
        client.disconnect()
        try await eventually { state.a.connectionID == nil }
        restarted.start(name: "Restart", key: key, port: port, advertise: false)
        try await eventually { state.receiver.listening }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(state.a.connected)
        XCTAssertEqual(state.receiver.connections, 0, "Cancel invalidates the scheduled retry")
    }
    func testMissingAcknowledgementsDoNotBlockPublicationAndCanRecover() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.setAcknowledgementsEnabled(false)
        receiver.updateOutputReadiness(.ready)
        receiver.start(name: "Feedback", key: key, advertise: false)
        let client = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        defer { client.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let id = UUID(), intent = UUID()
        client.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!), key: key, expectedReceiverID: nil, connectionID: id)
        try await eventually { state.a.connected && state.a.feedback.output == .ready }
        client.submit(.init(connectionID: id, content: .init(body: "First"), intent: intent))
        try await eventually { state.receiver.content.body == "First" && state.a.ownsOutput }
        try await eventually { state.a.feedback.overdue }
        XCTAssertTrue(state.a.connected)
        XCTAssertFalse(state.a.feedback.accepted)
        for index in 0..<2_000 { client.submit(.init(connectionID: id, content: .init(body: "Verse \(index)"), intent: intent)) }
        client.submit(.init(connectionID: id, content: .init(body: "Latest", visible: false), intent: intent))
        try await eventually { state.receiver.content.body == "Latest" }
        XCTAssertFalse(state.receiver.content.visible)
        XCTAssertTrue(state.a.connected, "Missing feedback never disconnects a healthy sender")
        receiver.setAcknowledgementsEnabled(true)
        try await eventually { state.a.feedback.accepted }
        XCTAssertFalse(state.a.feedback.overdue)
        receiver.updateOutputReadiness(.displayMissing)
        try await eventually { state.a.feedback.output == .displayMissing }
        XCTAssertTrue(state.a.feedback.accepted, "Acceptance does not imply a display is available")
        client.submit(.init(connectionID: id, content: nil, intent: nil))
        try await eventually { !state.a.ownsOutput && state.receiver.ownerName == nil }
        XCTAssertFalse(state.a.feedback.accepted)
    }
    func testEncryptedOwnershipBurstBlankReleaseAndReconnect() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.start(name: "Test", key: key, advertise: false)
        let a = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        let b = AltViewSenderClient(name: "B") { value in MainActor.assumeIsolated { state.b = value } }
        defer { a.disconnect(); b.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        let aID = UUID(), bID = UUID(), firstIntent = UUID()
        a.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: aID)
        b.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: bID)
        try await eventually { state.a.connected && state.b.connected }
        XCTAssertNil(state.receiver.ownerName, "Pairing alone cannot take output")
        a.submit(.init(connectionID: aID, content: .init(body: "First"), intent: firstIntent))
        try await eventually { state.receiver.content.body == "First" && state.a.ownsOutput }
        for index in 0..<2_000 {
            a.submit(.init(connectionID: aID, content: .init(body: "Verse \(index)"), intent: UUID()))
        }
        let currentIntent = UUID()
        a.submit(.init(connectionID: aID, content: .init(body: "Latest · മലയാളം", visible: false), intent: currentIntent))
        try await eventually { state.receiver.content.body == "Latest · മലയാളം" && !state.receiver.content.visible }
        receiver.dropConnections(named: "A")
        try await eventually { !state.a.connected }
        XCTAssertFalse(state.a.feedback.accepted)
        XCTAssertNil(state.a.feedback.output)
        a.submit(.init(connectionID: aID, content: .init(body: "Newest while offline", visible: false), intent: currentIntent))
        try await eventually { state.a.ownsOutput && state.receiver.content.body == "Newest while offline" }
        XCTAssertFalse(state.receiver.content.visible, "Reconnect preserves blanking")
        let bIntent = UUID()
        b.submit(.init(connectionID: bID, content: .init(body: "B owns output"), intent: bIntent))
        try await eventually { state.b.ownsOutput && !state.a.ownsOutput }
        XCTAssertFalse(state.a.feedback.accepted)
        XCTAssertEqual(state.a.feedback.sentRevision, 0)
        a.submit(.init(connectionID: aID, content: .init(body: "Automatic refresh"), intent: currentIntent))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.receiver.content.body, "B owns output", "Refresh cannot steal ownership")
        a.submit(.init(connectionID: aID, content: nil, intent: nil))
        b.submit(.init(connectionID: bID, content: .init(body: "B still owns output", visible: false), intent: bIntent))
        try await eventually { state.receiver.content.body == "B still owns output" }
        XCTAssertEqual(state.receiver.ownerName, "B", "Stopping A cannot clear B")
        b.submit(.init(connectionID: bID, content: nil, intent: nil))
        try await eventually { state.receiver.ownerName == nil && !state.receiver.content.visible }
    }
    func testReconnectCannotTakeFromAnotherSenderAndStopCancelsRestoration() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.start(name: "Test", key: key, advertise: false)
        let a = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        let b = AltViewSenderClient(name: "B") { value in MainActor.assumeIsolated { state.b = value } }
        defer { a.disconnect(); b.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        let aID = UUID(), bID = UUID(), aIntent = UUID()
        a.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: aID)
        b.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: bID)
        try await eventually { state.a.connected && state.b.connected }
        a.submit(.init(connectionID: aID, content: .init(body: "A"), intent: aIntent))
        try await eventually { state.a.ownsOutput }
        receiver.dropConnections(named: "A")
        try await eventually { !state.a.connected }
        XCTAssertFalse(state.a.feedback.accepted)
        XCTAssertNil(state.a.feedback.output)
        b.submit(.init(connectionID: bID, content: .init(body: "B"), intent: UUID()))
        try await eventually { state.b.ownsOutput }
        a.submit(.init(connectionID: aID, content: .init(body: "A automatic refresh", visible: false), intent: aIntent))
        try await eventually { state.a.connected }
        XCTAssertFalse(state.a.ownsOutput)
        XCTAssertEqual(state.receiver.content.body, "B")
        a.submit(.init(connectionID: aID, content: .init(body: "Explicit new projection"), intent: UUID()))
        try await eventually { state.a.ownsOutput }
        receiver.dropConnections(named: "A")
        try await eventually { !state.a.connected }
        XCTAssertFalse(state.a.feedback.accepted)
        XCTAssertNil(state.a.feedback.output)
        a.submit(.init(connectionID: aID, content: .init(body: "Cancelled offline projection"), intent: UUID()))
        try await Task.sleep(nanoseconds: 50_000_000)
        a.submit(.init(connectionID: aID, content: nil, intent: nil))
        try await eventually { state.a.connected }
        XCTAssertFalse(state.a.ownsOutput)
        XCTAssertNil(state.receiver.ownerName)
        XCTAssertEqual(state.receiver.content, .empty)
    }
    func testExplicitProjectionDuringReconnectTakesFromCurrentSender() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.start(name: "Handoff", key: key, advertise: false)
        let a = AltViewSenderClient(name: "ViewTheWord") { value in MainActor.assumeIsolated { state.a = value } }
        let b = AltViewSenderClient(name: "eucaly") { value in MainActor.assumeIsolated { state.b = value } }
        defer { a.disconnect(); b.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        let aID = UUID(), bID = UUID(), bIntent = UUID()
        a.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: aID)
        b.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: bID)
        try await eventually { state.a.connected && state.b.connected }
        b.submit(.init(connectionID: bID, content: .init(body: "Lyrics"), intent: bIntent))
        try await eventually { state.b.feedback.accepted && state.a.ownerName == "eucaly" }

        receiver.dropConnections(named: "ViewTheWord")
        try await eventually { state.a.waitingToRetry }
        a.submit(.init(connectionID: aID, content: .init(body: "Earlier verse"), intent: UUID()))
        let intent = UUID()
        a.submit(.init(connectionID: aID, content: .init(body: "Latest verse"), intent: intent))
        // Blank and translation refresh retain the queued explicit takeover.
        a.submit(.init(connectionID: aID, content: .init(body: "Latest translated verse", visible: false), intent: intent))
        try await eventually { state.a.feedback.accepted && state.receiver.content.body == "Latest translated verse" }
        XCTAssertEqual(state.a.connectionID, aID, "No manual reconnect is needed")
        XCTAssertTrue(state.a.ownsOutput)
        XCTAssertTrue(state.b.connected, "The previous sender keeps its connection")
        XCTAssertFalse(state.b.ownsOutput)
        XCTAssertFalse(state.receiver.content.visible)

        // Explicit verse activation takes output back over the same connection,
        // even if the text is identical to the previous local publication.
        b.submit(.init(connectionID: bID, content: .init(body: "Lyrics"), intent: UUID()))
        try await eventually { state.b.feedback.accepted && !state.a.ownsOutput }
        a.submit(.init(connectionID: aID, content: .init(body: "Latest translated verse"), intent: UUID()))
        try await eventually { state.a.feedback.accepted && state.receiver.content.body == "Latest translated verse" }
        XCTAssertEqual(state.receiver.connections, 2)
        XCTAssertTrue(state.receiver.content.visible)
    }
    func testExplicitTakeSurvivesDisconnectBeforeGrant() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.grantDelay = 0.4
        receiver.start(name: "Pending handoff", key: key, advertise: false)
        let a = AltViewSenderClient(name: "ViewTheWord") { value in MainActor.assumeIsolated { state.a = value } }
        let b = AltViewSenderClient(name: "eucaly") { value in MainActor.assumeIsolated { state.b = value } }
        defer { a.disconnect(); b.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        let aID = UUID(), bID = UUID()
        a.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: aID)
        b.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: bID)
        try await eventually { state.a.connected && state.b.connected }
        a.submit(.init(connectionID: aID, content: .init(body: "Requested verse"), intent: UUID()))
        try await eventually { state.receiver.ownerName == "ViewTheWord" }
        XCTAssertFalse(state.a.ownsOutput, "The grant has not arrived yet")
        receiver.dropConnections(named: "ViewTheWord")
        try await eventually { state.a.waitingToRetry }
        b.submit(.init(connectionID: bID, content: .init(body: "Lyrics"), intent: UUID()))
        try await eventually { state.b.feedback.accepted }
        try await eventually { state.a.feedback.accepted && state.receiver.content.body == "Requested verse" }
        XCTAssertTrue(state.a.ownsOutput)
        XCTAssertTrue(state.b.connected)
        XCTAssertEqual(state.a.connectionID, aID)
    }
    func testExplicitProjectionSurvivesStaleLeaseUntilOwnershipReportArrives() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.start(name: "Stale lease", key: key, advertise: false)
        let a = AltViewSenderClient(name: "ViewTheWord") { value in MainActor.assumeIsolated { state.a = value } }
        let b = AltViewSenderClient(name: "eucaly") { value in MainActor.assumeIsolated { state.b = value } }
        defer { a.disconnect(); b.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        let aID = UUID(), bID = UUID()
        a.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: aID)
        b.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: bID)
        try await eventually { state.a.connected && state.b.connected }
        a.submit(.init(connectionID: aID, content: .init(body: "First verse"), intent: UUID()))
        try await eventually { state.a.feedback.accepted }
        receiver.setOwnershipReportsSuspended(true, for: "ViewTheWord")
        b.submit(.init(connectionID: bID, content: .init(body: "Lyrics"), intent: UUID()))
        try await eventually { state.b.feedback.accepted && state.receiver.content.body == "Lyrics" }
        XCTAssertTrue(state.a.ownsOutput, "The sender has not received the lease revocation yet")
        let intent = UUID()
        a.submit(.init(connectionID: aID, content: .init(body: "Explicit verse"), intent: intent))
        try await eventually { state.receiver.rejectedSnapshots > 0 }
        XCTAssertEqual(state.receiver.content.body, "Lyrics")
        a.submit(.init(connectionID: aID, content: .init(body: "Newest verse", visible: false), intent: intent))
        try await eventually { state.receiver.rejectedSnapshots > 1 }
        receiver.setOwnershipReportsSuspended(false, for: "ViewTheWord")
        try await eventually { state.a.feedback.accepted && state.receiver.content.body == "Newest verse" }
        XCTAssertFalse(state.receiver.content.visible)
        XCTAssertTrue(state.b.connected)
        XCTAssertEqual(state.receiver.connections, 2)
        // Acceptance settles the explicit request. A later owner's projection wins.
        b.submit(.init(connectionID: bID, content: .init(body: "Later lyrics"), intent: UUID()))
        try await eventually { state.b.feedback.accepted && !state.a.ownsOutput }
        a.submit(.init(connectionID: aID, content: .init(body: "Background refresh"), intent: intent))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.receiver.content.body, "Later lyrics")
        XCTAssertFalse(state.a.ownsOutput)
    }
    func testStopCancelsExplicitProjectionWaitingForStaleLeaseRevocation() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        let a = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        let b = AltViewSenderClient(name: "B") { value in MainActor.assumeIsolated { state.b = value } }
        receiver.start(name: "Stale lease cancellation", key: key, advertise: false)
        defer { a.disconnect(); b.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        let aID = UUID(), bID = UUID()
        a.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: aID)
        b.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: bID)
        a.submit(.init(connectionID: aID, content: .init(body: "First"), intent: UUID()))
        try await eventually { state.a.feedback.accepted && state.b.connected }
        receiver.setOwnershipReportsSuspended(true, for: "A")
        b.submit(.init(connectionID: bID, content: .init(body: "Other app"), intent: UUID()))
        try await eventually { state.b.feedback.accepted && state.receiver.content.body == "Other app" }
        a.submit(.init(connectionID: aID, content: .init(body: "Cancelled request"), intent: UUID()))
        try await eventually { state.receiver.rejectedSnapshots > 0 }
        a.submit(.init(connectionID: aID, content: nil, intent: nil))
        try await eventually { !state.a.ownsOutput }
        receiver.setOwnershipReportsSuspended(false, for: "A")
        try await eventually { state.a.ownerName == "B" }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.receiver.content.body, "Other app")
        XCTAssertTrue(state.b.ownsOutput)
        XCTAssertFalse(state.a.ownsOutput)
    }
    func testIdleDisconnectBeforeResumeGrantStillRestoresLatestSnapshot() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.start(name: "Test", key: key, advertise: false)
        let a = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        let b = AltViewSenderClient(name: "B") { value in MainActor.assumeIsolated { state.b = value } }
        defer { a.disconnect(); b.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        let id = UUID(), intent = UUID()
        a.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: id)
        b.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: UUID())
        try await eventually { state.a.connected && state.b.connected }
        a.submit(.init(connectionID: id, content: .init(body: "First"), intent: intent))
        try await eventually { state.a.feedback.accepted }

        receiver.setResumesSuspended(true)
        receiver.dropConnections(named: "A")
        try await eventually { state.receiver.pendingResumes == 1 }
        a.submit(.init(connectionID: id, content: .init(body: "Latest", visible: false), intent: intent))
        b.disconnect()
        try await eventually { state.receiver.connections == 1 }
        receiver.setResumesSuspended(false)
        try await eventually { state.a.failureReason != nil || (state.a.feedback.accepted && state.receiver.content.body == "Latest") }
        XCTAssertNil(state.a.failureReason)
        XCTAssertTrue(state.a.connected)
        XCTAssertTrue(state.a.ownsOutput)
        XCTAssertEqual(state.receiver.content.body, "Latest")
        XCTAssertFalse(state.receiver.content.visible, "Restoration preserves the latest blanking state")
    }
    func testRefusedResumeStillAllowsExplicitTake() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.start(name: "Test", key: key, advertise: false)
        let a = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        let b = AltViewSenderClient(name: "B") { value in MainActor.assumeIsolated { state.b = value } }
        defer { a.disconnect(); b.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        let aID = UUID(), bID = UUID(), intent = UUID()
        a.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: aID)
        b.connect(to: endpoint, key: key, expectedReceiverID: nil, connectionID: bID)
        try await eventually { state.a.connected && state.b.connected }
        a.submit(.init(connectionID: aID, content: .init(body: "A"), intent: intent))
        try await eventually { state.a.feedback.accepted }

        receiver.setResumesSuspended(true)
        receiver.dropConnections(named: "A")
        try await eventually { state.receiver.pendingResumes == 1 }
        b.submit(.init(connectionID: bID, content: .init(body: "B"), intent: UUID()))
        try await eventually { state.b.feedback.accepted && state.a.ownerName == "B" }
        receiver.setResumesSuspended(false)
        try await eventually { state.receiver.pendingResumes == 0 }
        a.submit(.init(connectionID: aID, content: .init(body: "Automatic refresh", visible: false), intent: intent))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.receiver.content.body, "B", "A refused resume must not become an automatic takeover")
        XCTAssertTrue(state.b.ownsOutput)
        a.submit(.init(connectionID: aID, content: .init(body: "Explicit projection"), intent: UUID()))
        try await eventually { state.a.feedback.accepted && state.receiver.content.body == "Explicit projection" }
        XCTAssertNil(state.a.failureReason)
        XCTAssertTrue(state.a.ownsOutput)
    }
    func testStopWhileTakeIsInFlightNeverPublishesLateGrant() async throws {
        let state = AltViewNetworkObservation()
        let receiver = FixtureReceiverServer(receiverID: UUID()) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.grantDelay = 0.4
        receiver.start(name: "Test", key: key, advertise: false)
        let client = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        defer { client.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let id = UUID()
        client.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!), key: key, expectedReceiverID: nil, connectionID: id)
        try await eventually { state.a.connected }
        client.submit(.init(connectionID: id, content: .init(body: "Must never appear"), intent: UUID()))
        try await eventually { state.receiver.ownerName == "A" }
        client.submit(.init(connectionID: id, content: nil, intent: nil))
        try await eventually { state.receiver.ownerName == nil && state.a.connected }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(state.receiver.content, .empty)
        XCTAssertFalse(state.a.ownsOutput)
    }
    func testWrongCodeIdentityPinAndEscapedFrameLimit() async throws {
        let state = AltViewNetworkObservation()
        let receiverID = UUID()
        let receiver = FixtureReceiverServer(receiverID: receiverID) { value in MainActor.assumeIsolated { state.receiver = value } }
        receiver.start(name: "Test", key: key, advertise: false)
        let client = AltViewSenderClient(name: "A") { value in MainActor.assumeIsolated { state.a = value } }
        defer { client.disconnect(); receiver.stop() }
        try await eventually { state.receiver.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: state.receiver.port!)!)
        client.connect(to: endpoint, key: Data("ABCD2346".utf8), expectedReceiverID: nil, connectionID: UUID())
        try await eventually { state.a.failureReason != nil }
        XCTAssertFalse(state.a.connected)
        client.connect(to: endpoint, key: key, expectedReceiverID: UUID(), connectionID: UUID())
        try await eventually { state.a.failureReason?.contains("identity changed") == true }
        XCTAssertFalse(state.a.connected)
        let id = UUID()
        client.connect(to: endpoint, key: key, expectedReceiverID: receiverID, connectionID: id)
        try await eventually { state.a.connected }
        client.submit(.init(connectionID: id, content: .init(body: "Good"), intent: UUID()))
        try await eventually { state.a.ownsOutput }
        let rejectedIntent = UUID()
        client.submit(.init(connectionID: id, content: .init(body: String(repeating: "\u{01}", count: 24_000)), intent: rejectedIntent))
        try await eventually { state.a.outputIssue?.contains("text limit") == true && state.receiver.ownerName == nil }
        XCTAssertTrue(state.a.connected, "Oversized text does not break the connection or local projection")
        client.submit(.init(connectionID: id, content: .init(body: "Automatic refresh after rejection"), intent: rejectedIntent))
        try await eventually { state.a.outputIssue == nil }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(state.receiver.ownerName, "Recovering valid text is still an automatic refresh, not a takeover")
    }
}
