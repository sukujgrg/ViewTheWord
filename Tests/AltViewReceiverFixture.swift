// Receiver fixture copied from AltView protocol v2 (2026-10-02), with test-only names; template discovery updated 2026-10-03.
@testable import ViewTheWordCore
import Foundation

struct FixtureSenderIdentity: Equatable, Sendable {
    let id: UUID
    let name: String
}

/// Pure ownership rules, confined to FixtureReceiverServer's serial queue in production.
struct FixtureReceiverState {
    private(set) var senders: [UUID: FixtureSenderIdentity] = [:]
    private(set) var ownerConnection: UUID?
    private(set) var lease: UUID?
    private(set) var revision: UInt64 = 0
    private(set) var content = AltViewDisplayContent.empty
    var owner: FixtureSenderIdentity? { ownerConnection.flatMap { senders[$0] } }

    mutating func register(connection: UUID, senderID: UUID, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard senders[connection] == nil, !name.isEmpty, name.utf8.count <= 128 else { return false }
        senders[connection] = FixtureSenderIdentity(id: senderID, name: name)
        return true
    }
    mutating func take(connection: UUID, onlyIfUnowned: Bool = false) -> UUID? {
        guard senders[connection] != nil, !onlyIfUnowned || ownerConnection == nil else { return nil }
        ownerConnection = connection
        lease = UUID()
        revision = 0
        content = .empty
        return lease
    }
    @discardableResult
    mutating func apply(connection: UUID, lease: UUID, revision: UInt64, content: AltViewDisplayContent) -> Bool {
        guard ownerConnection == connection, self.lease == lease, revision > self.revision, content.isValid else { return false }
        self.revision = revision
        self.content = content
        return true
    }
    @discardableResult
    mutating func release(connection: UUID, lease: UUID?) -> Bool {
        guard ownerConnection == connection, self.lease == lease else { return false }
        clearOwner()
        return true
    }
    mutating func disconnect(_ connection: UUID) {
        senders.removeValue(forKey: connection)
        if ownerConnection == connection { clearOwner() }
    }
    mutating func clearOwner() {
        ownerConnection = nil
        lease = nil
        revision = 0
        content = .empty
    }
}

import Foundation
import Network

struct FixtureReceiverStatus: Equatable, Sendable {
    var listening = false
    var port: UInt16?
    var connections = 0
    var pendingResumes = 0
    var rejectedSnapshots = 0
    var connectedSenders: [FixtureSenderIdentity] = []
    var ownerID: UUID?
    var ownerName: String?
    var content = AltViewDisplayContent.empty
    var revision: UInt64 = 0
    var message = "Receiving is off"
}

final class FixtureReceiverServer: @unchecked Sendable {
    let receiverID: UUID
    private let capabilities: [String]
    private let queue = DispatchQueue(label: "com.suku.AltView.receiver", qos: .userInitiated)
    private var listener: NWListener?
    private var peers: [UUID: AltViewPeerChannel] = [:]
    private var templateCapabilities = AltViewTemplateCapabilities()
    private var outputReadiness = AltViewOutputReadiness.closed
    private var state = FixtureReceiverState()
    private var status = FixtureReceiverStatus()
    private var timer: DispatchSourceTimer?
    private let delivery: AltViewSnapshotMailbox<FixtureReceiverStatus>

    init(receiverID: UUID, capabilities: [String] = [], callbackQueue: DispatchQueue = .main, onStatus: @escaping @Sendable (FixtureReceiverStatus) -> Void) {
        self.receiverID = receiverID
        self.capabilities = capabilities
        delivery = AltViewSnapshotMailbox(queue: callbackQueue, consume: onStatus)
    }
    func start(name: String, key: Data, port: UInt16 = 0, advertise: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            do {
                let listener = try NWListener(using: AltViewSecureConnection.parameters(key: key), on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                if advertise {
                    // Public identity lets discovery omit this Mac; pairing secrets never leave TLS.
                    listener.service = NWListener.Service(name: name, type: AltViewProtocol.serviceType,
                        txtRecord: NWTXTRecord(["receiverID": self.receiverID.uuidString]))
                }
                listener.stateUpdateHandler = { [weak self, weak listener] newState in
                    guard let self, let listener, self.listener === listener else { return }
                    switch newState {
                    case .ready:
                        self.status.listening = true
                        self.status.port = listener.port?.rawValue
                        self.status.message = "Ready for senders"
                        self.publish()
                    case .failed(let error), .waiting(let error):
                        self.stopOnQueue()
                        self.status.message = "Could not receive: \(error.localizedDescription)"
                        self.publish()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    for peer in Array(self.peers.values) {
                        peer.send(AltViewWireMessage(kind: .heartbeat))
                        peer.checkTimeout(now: now)
                    }
                }
                self.timer = timer
                timer.resume()
            } catch {
                self.status.message = "Could not start receiver: \(error.localizedDescription)"
                self.publish()
            }
        }
    }
    // Allows legacy, changing and intentionally malformed discovery reports.
    func updateTemplateCapabilities(_ capabilities: AltViewTemplateCapabilities) {
        queue.async { [weak self] in
            self?.templateCapabilities = capabilities
            self?.broadcastFeedback()
        }
    }
    func updateOutputReadiness(_ readiness: AltViewOutputReadiness) {
        queue.async { [weak self] in
            guard let self, self.outputReadiness != readiness else { return }
            self.outputReadiness = readiness
            self.broadcastFeedback()
        }
    }
    func stop() { queue.async { [weak self] in self?.stopOnQueue(); self?.publish() } }
    var grantDelay: TimeInterval = 0
    private var resumesSuspended = false
    private var suspendedResumes = Set<UUID>()
    func setResumesSuspended(_ suspended: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.resumesSuspended = suspended
            if !suspended {
                let pending = self.suspendedResumes
                self.suspendedResumes.removeAll()
                for id in pending {
                    if let peer = self.peers[id] { self.handle(AltViewWireMessage(kind: .resume), from: peer) }
                }
            }
            self.publish()
        }
    }
    private var acknowledgementsEnabled = true
    func setAcknowledgementsEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            self?.acknowledgementsEnabled = enabled
            self?.broadcastFeedback()
        }
    }
    func dropConnections(named name: String? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            for peer in Array(self.peers.values) where name == nil || self.state.senders[peer.id]?.name == name { peer.close("Test network interruption") }
        }
    }
    func clearOutput() {
        queue.async { [weak self] in
            guard let self else { return }
            self.state.clearOwner()
            self.status.message = "Ready for senders"
            self.broadcastOwnership()
            self.publish()
        }
    }
    private var suspendedOwnershipNames = Set<String>()
    func setOwnershipReportsSuspended(_ suspended: Bool, for name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if suspended { self.suspendedOwnershipNames.insert(name) }
            else {
                self.suspendedOwnershipNames.remove(name)
                self.broadcastOwnership()
            }
        }
    }
    private func stopOnQueue() {
        timer?.cancel(); timer = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let closing = Array(peers.values)
        peers.removeAll()
        suspendedResumes.removeAll()
        for peer in closing { peer.onClose = nil; peer.close(nil) }
        state = FixtureReceiverState()
        suspendedOwnershipNames.removeAll()
        status = FixtureReceiverStatus()
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < AltViewProtocol.maximumClients else { connection.cancel(); return }
        let peer = AltViewPeerChannel(connection: connection, queue: queue)
        peers[peer.id] = peer
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.handle(message, from: peer)
        }
        peer.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peers.removeValue(forKey: peer.id) != nil else { return }
            let wasOwner = self.state.ownerConnection == peer.id
            self.suspendedResumes.remove(peer.id)
            self.state.disconnect(peer.id)
            if wasOwner { self.status.message = "Sender disconnected — output cleared" }
            self.broadcastOwnership()
            self.publish()
        }
        peer.start()
        // An authenticated peer must identify itself, even if it sends heartbeats.
        queue.asyncAfter(deadline: .now() + AltViewProtocol.timeout) { [weak self, weak peer] in
            guard let self, let peer, self.peers[peer.id] != nil, self.state.senders[peer.id] == nil else { return }
            peer.close("Sender did not identify itself.")
        }
    }
    private func handle(_ message: AltViewWireMessage, from peer: AltViewPeerChannel) {
        guard message.version == AltViewProtocol.version else { peer.close("Unsupported protocol version."); return }
        if message.kind == .hello {
            guard let id = message.senderID, let name = message.name, state.register(connection: peer.id, senderID: id, name: name) else {
                peer.close("Invalid sender identity."); return
            }
            peer.send(AltViewWireMessage(kind: .welcome, receiverID: receiverID, ownerID: state.owner?.id, ownerName: state.owner?.name,
                templates: templateCapabilities.templates, templatePolicy: templateCapabilities.policy, capabilities: capabilities))
            sendFeedback(to: peer)
            publish()
            return
        }
        guard state.senders[peer.id] != nil else { peer.close("Identify sender first."); return }
        // Deterministically place another connection's ownership broadcast
        // before the response to a reconnecting sender's resume request.
        if message.kind == .resume, resumesSuspended {
            suspendedResumes.insert(peer.id)
            publish()
            return
        }
        switch message.kind {
        case .take, .resume:
            guard let lease = state.take(connection: peer.id, onlyIfUnowned: message.kind == .resume) else {
                broadcastOwnership(); return
            }
            status.message = "Receiving from \(state.owner!.name)"
            if grantDelay > 0 {
                queue.asyncAfter(deadline: .now() + grantDelay) { [weak self, weak peer] in
                    guard let self, let peer, self.peers[peer.id] != nil else { return }
                    peer.send(AltViewWireMessage(kind: .granted, lease: lease))
                    self.broadcastOwnership()
                }
            } else {
                peer.send(AltViewWireMessage(kind: .granted, lease: lease))
                broadcastOwnership()
            }
            publish()
        case .state:
            guard let lease = message.lease, let revision = message.revision, let content = message.content, content.isValid else {
                peer.close("Invalid content snapshot."); return
            }
            if state.apply(connection: peer.id, lease: lease, revision: revision, content: content) {
                publish()
                sendFeedback(to: peer)
            } else {
                status.rejectedSnapshots += 1
                publish()
            }
        case .release:
            if state.release(connection: peer.id, lease: message.lease) {
                status.message = "Ready for senders"
                broadcastOwnership()
                publish()
            }
        case .heartbeat: break
        default: peer.close("Unexpected sender message.")
        }
    }
    private func broadcastOwnership() {
        let message = AltViewWireMessage(kind: .ownership, lease: state.lease, ownerID: state.owner?.id, ownerName: state.owner?.name)
        for (id, peer) in peers {
            guard let sender = state.senders[id], !suspendedOwnershipNames.contains(sender.name) else { continue }
            peer.send(message)
        }
        broadcastFeedback()
    }
    private func broadcastFeedback() {
        for peer in peers.values { sendFeedback(to: peer) }
    }
    private func sendFeedback(to peer: AltViewPeerChannel) {
        guard state.senders[peer.id] != nil else { return }
        let hasSnapshot = acknowledgementsEnabled && state.ownerConnection == peer.id && state.revision > 0
        peer.send(AltViewWireMessage(kind: .feedback, lease: hasSnapshot ? state.lease : nil,
                              revision: hasSnapshot ? state.revision : nil, outputReadiness: outputReadiness,
                              templates: templateCapabilities.templates, templatePolicy: templateCapabilities.policy))
    }
    private func publish() {
        status.connections = state.senders.count
        status.pendingResumes = suspendedResumes.count
        status.connectedSenders = state.senders.values.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
        }
        status.ownerID = state.owner?.id
        status.ownerName = state.owner?.name
        status.content = state.content
        status.revision = state.revision
        delivery.offer(status)
    }
}
