import Foundation
import Network

struct AltViewSenderStatus: Equatable, Sendable {
    var connectionID: UUID?
    var connected = false
    var ownsOutput = false
    var receiverID: UUID?
    var ownerName: String?
    var message = "Not connected"
    var failureReason: String?
    var feedback = AltViewDeliveryFeedback()
    var outputIssue: String?
    var submissionID: UUID?
}

/// The intent is retained across blank/translation updates, and changes only for
/// an explicit publication. This prevents background updates from taking output.
struct AltViewSubmission: Sendable {
    let id = UUID()
    let connectionID: UUID
    let content: AltViewDisplayContent?
    let intent: UUID?
}

protocol AltViewSending: AnyObject {
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID)
    func submit(_ submission: AltViewSubmission)
    func disconnect()
}

/// Mutable transport state belongs exclusively to queue. The only cross-queue
/// input is a bounded mailbox; encoding and socket work never run on the UI thread.
final class AltViewSenderClient: AltViewSending, @unchecked Sendable {
    private let senderID = UUID()
    private let name: String
    private let queue = DispatchQueue(label: "suku.ViewTheWord.altview.sender", qos: .userInitiated)
    private var peer: AltViewPeerChannel?
    private var endpoint: NWEndpoint?
    private var key: Data?
    private var expectedReceiverID: UUID?
    private var reconnectWork: DispatchWorkItem?
    private var attempts = 0
    private var initialDeadline: TimeInterval?
    private var timer: DispatchSourceTimer?
    private var lease: UUID?
    private var revision: UInt64 = 0
    private var latest: AltViewDisplayContent?
    private var lastIntent: UUID?
    private var pendingTake = false
    private enum GrantRequest { case take, resume }
    private var awaitingGrant: GrantRequest?
    private var wantsConnection = false
    private var restoreOwnership = false
    private var status = AltViewSenderStatus()
    private let delivery: AltViewSnapshotMailbox<AltViewSenderStatus>
    private let inputLock = NSLock()
    private var submissions: AltViewSnapshotMailbox<AltViewSubmission>?

    init(name: String, callbackQueue: DispatchQueue = .main,
         onStatus: @escaping @Sendable (AltViewSenderStatus) -> Void) {
        // Truncate by characters, preserving valid UTF-8 within the protocol bound.
        var name = name
        while name.utf8.count > 128 { name.removeLast() }
        self.name = name.isEmpty ? "ViewTheWord" : name
        delivery = AltViewSnapshotMailbox(queue: callbackQueue, consume: onStatus)
    }
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID) {
        inputLock.lock()
        defer { inputLock.unlock() }
        // A mailbox per connection prevents a new destination's snapshot from
        // being drained by a job queued before that destination's connect command.
        submissions = AltViewSnapshotMailbox(queue: queue) { [weak self] in self?.apply($0) }
        queue.async { [weak self] in
            guard let self else { return }
            self.disconnectOnQueue()
            self.status.connectionID = connectionID
            self.endpoint = endpoint; self.key = key; self.expectedReceiverID = expectedReceiverID
            self.wantsConnection = true
            self.initialDeadline = ProcessInfo.processInfo.systemUptime + AltViewProtocol.connectionTimeout
            self.openConnection()
        }
    }
    func submit(_ submission: AltViewSubmission) {
        let mailbox = inputLock.withLock { submissions }
        mailbox?.offer(submission)
    }
    func disconnect() {
        inputLock.withLock {
            submissions = nil
            queue.async { [weak self] in self?.disconnectOnQueue(); self?.publish() }
        }
    }
    private func stopTransport() {
        reconnectWork?.cancel(); reconnectWork = nil
        timer?.cancel(); timer = nil
        peer?.onClose = nil; peer?.close(nil); peer = nil
        lease = nil; awaitingGrant = nil
        status.connected = false; status.ownsOutput = false
        status.feedback = AltViewDeliveryFeedback()
    }
    private func disconnectOnQueue() {
        wantsConnection = false; restoreOwnership = false; pendingTake = false
        initialDeadline = nil; latest = nil; lastIntent = nil; attempts = 0
        stopTransport()
        endpoint = nil; key = nil; expectedReceiverID = nil
        status = AltViewSenderStatus()
    }
    private func apply(_ submission: AltViewSubmission) {
        guard wantsConnection, submission.connectionID == status.connectionID else { return }
        guard let content = submission.content else { status.outputIssue = nil; stopOutput(); return }
        // Check escaped JSON size before taking output, as well as text bounds.
        guard content.isValid,
              (try? AltViewFrameCodec.encode(AltViewWireMessage(kind: .state, lease: UUID(), revision: UInt64.max, content: content))) != nil else {
            stopOutput()
            lastIntent = submission.intent // A later automatic refresh still cannot take output.
            status.outputIssue = "AltView text limit exceeded; remote output stopped."
            publish()
            return
        }
        if status.outputIssue != nil { status.outputIssue = nil; publish() }
        latest = content
        status.submissionID = submission.id
        let explicit = submission.intent != nil && submission.intent != lastIntent
        lastIntent = submission.intent
        if explicit, status.connected, lease == nil, awaitingGrant == nil {
            awaitingGrant = .take
            peer?.discardPendingState()
            peer?.send(AltViewWireMessage(kind: .take))
        } else if explicit, !status.connected, initialDeadline != nil {
            pendingTake = true
        }
        // During established reconnects only a former owner can resume, and only
        // if unowned. Offline activity must not later steal another sender's output.
        sendLatest()
    }
    private func stopOutput() {
        latest = nil; lastIntent = nil; pendingTake = false; restoreOwnership = false
        peer?.discardPendingState()
        if awaitingGrant != nil {
            // A take cannot be cancelled on the wire. Closing the socket invalidates a late grant.
            stopTransport()
            if wantsConnection { openConnection() }
        } else {
            if let lease { peer?.send(AltViewWireMessage(kind: .release, lease: lease)) }
            lease = nil; status.ownsOutput = false
            status.feedback.resetSnapshot()
            if status.connected { status.message = "Connected · waiting for projection" }
            publish()
        }
    }
    private func openConnection() {
        guard wantsConnection, let endpoint, let key else { return }
        let setupTimeout: TimeInterval
        if let deadline = initialDeadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { fail("Connection timed out. Check AltView and Local Network access on both Macs."); return }
            setupTimeout = min(AltViewProtocol.connectionAttemptTimeout, remaining)
            status.message = "Connecting…"
        } else { setupTimeout = AltViewProtocol.connectionTimeout; status.message = "Reconnecting…" }
        status.failureReason = nil
        publish()
        let peer = AltViewPeerChannel(connection: NWConnection(to: endpoint, using: AltViewSecureConnection.parameters(key: key)),
                                      queue: queue, connectionTimeout: setupTimeout)
        self.peer = peer
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            peer.send(AltViewWireMessage(kind: .hello, senderID: self.senderID, name: self.name))
            self.queue.asyncAfter(deadline: .now() + AltViewProtocol.timeout) { [weak self, weak peer] in
                guard let self, let peer, self.peer === peer, !self.status.connected else { return }
                peer.close("Receiver did not complete the handshake.")
            }
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.peer === peer else { return }
            self.handle(message)
        }
        peer.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peer === peer else { return }
            self.restoreOwnership = self.status.ownsOutput || self.restoreOwnership
            self.peer = nil; self.lease = nil; self.awaitingGrant = nil
            self.status.connected = false; self.status.ownsOutput = false
            self.status.feedback = AltViewDeliveryFeedback()
            self.timer?.cancel(); self.timer = nil
            if let deadline = self.initialDeadline {
                if self.wantsConnection, peer.retryableSetupFailure, ProcessInfo.processInfo.systemUptime < deadline {
                    self.status.message = "Connecting… Retrying the network connection."
                    self.publish(); self.scheduleReconnect()
                } else { self.fail(reason ?? "The receiving Mac closed the connection.") }
                return
            }
            self.status.message = "Disconnected. \(reason ?? "") Retrying…"
            self.publish(); self.scheduleReconnect()
        }
        peer.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            if self.status.connected { peer.send(AltViewWireMessage(kind: .heartbeat)) }
            if self.status.feedback.checkTimeout(now: ProcessInfo.processInfo.systemUptime) { self.publish() }
            peer.checkTimeout(now: ProcessInfo.processInfo.systemUptime)
        }
        self.timer = timer; timer.resume()
    }
    private func handle(_ message: AltViewWireMessage) {
        guard message.isValidReceiverMessage else { fail("Invalid AltView response."); return }
        switch message.kind {
        case .welcome:
            guard !status.connected, let receiverID = message.receiverID else { fail("Invalid welcome."); return }
            if let expectedReceiverID, expectedReceiverID != receiverID { fail("Receiver identity changed. Enter its code to pair again."); return }
            status.feedback = AltViewDeliveryFeedback()
            expectedReceiverID = receiverID
            initialDeadline = nil; attempts = 0
            status.connected = true; status.receiverID = receiverID; status.ownerName = message.ownerName
            status.message = message.ownerName.map { "Connected · output controlled by \($0)" } ?? "Connected · waiting for projection"
            if pendingTake, latest != nil {
                pendingTake = false; awaitingGrant = .take; peer?.send(AltViewWireMessage(kind: .take))
            } else if restoreOwnership, latest != nil, message.ownerID == nil {
                awaitingGrant = .resume; peer?.send(AltViewWireMessage(kind: .resume))
            } else { restoreOwnership = false }
            publish()
        case .granted:
            guard status.connected, awaitingGrant != nil, let lease = message.lease else { fail("Unexpected AltView grant."); return }
            awaitingGrant = nil; self.lease = lease; revision = 0
            status.feedback.resetSnapshot()
            status.ownsOutput = true; restoreOwnership = true
            status.message = "Sending projected verse"
            sendLatest(); publish()
        case .ownership:
            guard status.connected else { fail("Ownership before welcome."); return }
            status.ownerName = message.ownerName
            if message.ownerID != senderID || message.lease != lease {
                lease = nil; status.ownsOutput = false; restoreOwnership = false
                status.feedback.resetSnapshot()
                // An ownership broadcast can precede the response to our take.
                // A refused resume also ends the pending grant.
                if awaitingGrant == .resume { awaitingGrant = nil }
                peer?.discardPendingState()
                status.message = message.ownerName.map { "Output controlled by \($0)" } ?? "Connected · waiting for projection"
            }
            publish()
        case .feedback:
            guard status.connected, message.outputReadiness != nil,
                  (message.lease == nil && message.revision == nil) || (message.lease != nil && message.revision.map { $0 > 0 } == true) else {
                peer?.close("Unexpected output feedback."); return
            }
            status.feedback.receive(message, lease: lease, now: ProcessInfo.processInfo.systemUptime)
            publish()
        case .heartbeat: break
        case .error: fail(message.detail ?? "AltView rejected the message.")
        default: fail("Unexpected AltView response.")
        }
    }
    private func sendLatest() {
        guard let latest, let lease, status.connected else { return }
        guard revision < UInt64.max else { fail("Session revision exhausted. Connect again."); return }
        revision += 1
        status.feedback.sent(revision, now: ProcessInfo.processInfo.systemUptime)
        peer?.send(AltViewWireMessage(kind: .state, lease: lease, revision: revision, content: latest))
        publish()
    }
    private func scheduleReconnect() {
        guard wantsConnection else { return }
        let delay = initialDeadline.map { min(1, max(0, $0 - ProcessInfo.processInfo.systemUptime)) }
            ?? min(8, pow(2, Double(min(attempts, 3))))
        attempts += 1
        let id = status.connectionID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsConnection, self.status.connectionID == id, self.peer == nil else { return }
            self.reconnectWork = nil; self.openConnection()
        }
        reconnectWork = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func fail(_ reason: String) {
        wantsConnection = false; restoreOwnership = false; pendingTake = false; initialDeadline = nil
        stopTransport()
        status.failureReason = reason; status.message = reason
        publish()
    }
    private func publish() { delivery.offer(status) }
}
