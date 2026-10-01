import AppKit
import Combine
import Network

/// App-scoped adapter. Connecting never publishes the existing projection.
/// Only committed projection intents feed the sender; browsing and view rendering
/// have no remote side effects. All failures are informational to local projection.
@MainActor
final class AltViewProjectionService: ObservableObject {
    @Published private(set) var status = AltViewSenderStatus()
    @Published private(set) var isEnabled = false
    @Published private(set) var pairingNote: String?
    private(set) var destination: AltViewDestination?
    private(set) var currentContent: AltViewDisplayContent?
    private var connectionID: UUID?
    private var publicationIntent: UUID?
    private var latestSubmissionID: UUID?
    private var startedSender = false
    private var pairings: [String: AltViewPairing] = [:]
    private var pendingKey: Data?
    private var savedConnectionID: UUID?
    private var connectionTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let store: any AltViewPairingStoring
    private let senderFactory: (@escaping @Sendable (AltViewSenderStatus) -> Void) -> any AltViewSending
    private lazy var sender: any AltViewSending = senderFactory { [weak self] status in
        MainActor.assumeIsolated { self?.receive(status) }
    }

    init(defaults: UserDefaults = .standard, store: any AltViewPairingStoring = AltViewPairingStore(),
         senderFactory: @escaping (@escaping @Sendable (AltViewSenderStatus) -> Void) -> any AltViewSending = {
             AltViewSenderClient(name: "ViewTheWord · \(Host.current().localizedName ?? "Mac")", onStatus: $0)
         }) {
        self.defaults = defaults; self.store = store; self.senderFactory = senderFactory
        if let data = defaults.data(forKey: AppDefaultsKey.altViewDestination),
           let saved = try? JSONDecoder().decode(AltViewDestination.self, from: data), saved.isValid { destination = saved }
    }

    var summary: String {
        guard isEnabled else { return "AltView off" }
        if status.outputIssue != nil { return "AltView · text too long" }
        if status.ownsOutput {
            if let output = status.feedback.output, output != .ready { return "AltView · \(output.summary.lowercased())" }
            if status.feedback.overdue { return "AltView · acknowledgement delayed" }
            if status.submissionID == latestSubmissionID, status.feedback.accepted { return "AltView · snapshot accepted" }
            return "AltView · awaiting acknowledgement"
        }
        if status.connected { return status.ownerName == nil ? "AltView · ready" : "AltView · another sender" }
        return status.failureReason == nil ? "AltView · connecting" : "AltView · unavailable"
    }
    var detail: String {
        let feedback: String? = status.connected
            ? (status.ownsOutput && status.submissionID != latestSubmissionID
                ? "Sending latest snapshot. \(status.feedback.output?.summary ?? "Waiting for display status")."
                : status.feedback.detail) : nil
        return [status.message, status.outputIssue, feedback, pairingNote].compactMap { $0 }.joined(separator: "\n")
    }

    func connect(to destination: AltViewDestination, code: String) {
        guard destination.isValid else { pairingNote = "Enter a host name and a port from 1 to 65535."; return }
        let enteredCode = !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let parsed = AltViewPairingKey.parse(code)
        guard !enteredCode || parsed != nil else { pairingNote = "Enter the eight-character pairing code shown in AltView."; return }
        disconnect()
        self.destination = destination
        let id = UUID()
        connectionID = id; isEnabled = true; pairingNote = nil
        status = AltViewSenderStatus(connectionID: id, message: "Preparing connection…")
        let remembered = pairings[destination.account]
        connectionTask = Task { [weak self, store] in
            var pairing = remembered
            if parsed == nil, pairing == nil { pairing = try? await store.read(account: destination.account) }
            guard let self, !Task.isCancelled, self.connectionID == id else { return }
            guard let key = parsed ?? pairing?.key else {
                self.status = AltViewSenderStatus(connectionID: id, message: "Enter the pairing code shown in AltView.", failureReason: "Pairing code required")
                self.publicationIntent = nil
                return
            }
            self.pendingKey = key
            self.startedSender = true
            self.sender.connect(to: destination.endpoint, key: key, expectedReceiverID: parsed == nil ? pairing?.receiverID : nil, connectionID: id)
            if self.publicationIntent != nil { self.submit() }
        }
    }
    func disconnect() {
        connectionTask?.cancel(); connectionTask = nil
        connectionID = nil; publicationIntent = nil; pendingKey = nil; savedConnectionID = nil
        if startedSender { sender.disconnect() }
        startedSender = false; isEnabled = false
        status = AltViewSenderStatus(); pairingNote = nil; latestSubmissionID = nil
    }
    func publish(_ projection: PreparedProjection, blanked: Bool, explicit: Bool) {
        let data = projection.data
        currentContent = AltViewDisplayContent(title: data.title, body: data.primaryText,
                                              footer: data.primaryTranslationName, visible: !blanked)
        guard connectionID != nil else { return }
        if explicit { publicationIntent = UUID() }
        guard publicationIntent != nil else { return }
        submit()
    }
    func setBlanked(_ blanked: Bool) {
        currentContent?.visible = !blanked
        if publicationIntent != nil { submit() }
    }
    func stop() {
        currentContent = nil; publicationIntent = nil
        submit()
    }
    private func submit() {
        guard let connectionID, startedSender else { return }
        let submission = AltViewSubmission(connectionID: connectionID, content: currentContent, intent: publicationIntent)
        latestSubmissionID = submission.id
        sender.submit(submission)
    }
    private func receive(_ status: AltViewSenderStatus) {
        guard let connectionID, status.connectionID == connectionID else { return }
        self.status = status
        if status.failureReason != nil { publicationIntent = nil }
        guard status.connected, savedConnectionID != connectionID,
              let receiverID = status.receiverID, let key = pendingKey, let destination else { return }
        savedConnectionID = connectionID
        let pairing = AltViewPairing(key: key, receiverID: receiverID)
        pairings[destination.account] = pairing
        defaults.set(try? JSONEncoder().encode(destination), forKey: AppDefaultsKey.altViewDestination)
        Task { [weak self, store] in
            do { try await store.save(pairing, account: destination.account) }
            catch {
                guard let self, self.connectionID == connectionID else { return }
                self.pairingNote = "Connected for this session. Pairing could not be saved in Keychain; enter the code again after restarting."
            }
        }
    }
}
