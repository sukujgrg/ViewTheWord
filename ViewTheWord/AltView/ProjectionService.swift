import AppKit
import Combine
import Network

enum AltViewConfigurationChange {
    case template(AltViewContentTemplate?)
    case paired(AltViewDestination, UUID)
}

/// One destination's adapter. Connecting never publishes the existing projection.
/// Only committed projection intents feed the sender; browsing and view rendering
/// have no remote side effects. All failures are informational to local projection.
@MainActor
final class AltViewProjectionService: ObservableObject {
    @Published private(set) var status = AltViewSenderStatus()
    @Published private(set) var isEnabled = false
    @Published private(set) var pairingNote: String?
    // A private choice until the next explicit projection. Empty saved value means receiver layout.
    @Published private(set) var selectedTemplate: AltViewContentTemplate? = .scripture
    let discovery: AltViewDiscoveryService
    var receivers: [AltViewDestination] { discovery.receivers }
    var discoveryNote: String? { discovery.note }
    private let discoveryID = UUID()
    private let visibleDiscoveryID = UUID()
    private var discoverySubscription: AnyCancellable?
    var onConfigurationChanged: (AltViewConfigurationChange) -> Void = { _ in }
    var validateReceiver: (AltViewDestination, UUID?) -> String? = { _, _ in nil }
    private var identityValidated = false
    var hasPublication: Bool { publicationIntent != nil }
    private(set) var destination: AltViewDestination?
    private(set) var currentContent: AltViewDisplayContent?
    private var connectionID: UUID?
    private var publicationIntent: UUID?
    private var latestSubmissionID: UUID?
    private var startedSender = false
    private var pairings: [String: AltViewPairing] = [:]
    private var pendingKey: Data?
    private var pendingReceiverID: UUID?
    private var savedConnectionID: UUID?
    private var connectionTask: Task<Void, Never>?
    private let store: any AltViewPairingStoring
    private let senderFactory: (@escaping @Sendable (AltViewSenderStatus) -> Void) -> any AltViewSending
    private lazy var sender: any AltViewSending = senderFactory { [weak self] status in
        MainActor.assumeIsolated { self?.receive(status) }
    }

    init(destination: AltViewDestination? = nil, template: AltViewContentTemplate? = .scripture,
         store: any AltViewPairingStoring = AltViewPairingStore(), discovery: AltViewDiscoveryService? = nil,
         senderFactory: @escaping (@escaping @Sendable (AltViewSenderStatus) -> Void) -> any AltViewSending = {
             AltViewSenderClient(name: "ViewTheWord · \(Host.current().localizedName ?? "Mac")", onStatus: $0)
         }) {
        self.store = store; self.senderFactory = senderFactory
        self.destination = destination; self.selectedTemplate = template
        self.discovery = discovery ?? AltViewDiscoveryService()
        discoverySubscription = self.discovery.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiveDiscovered(self.discovery.receivers, notice: self.discovery.note)
            }
        }
    }
    isolated deinit {
        connectionTask?.cancel()
        discovery.request(discoveryID, needed: false)
        discovery.request(visibleDiscoveryID, needed: false)
        if startedSender { sender.disconnect() }
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
        if status.waitingToRetry { return "AltView · waiting to reconnect" }
        return status.failureReason == nil ? "AltView · connecting" : "AltView · unavailable"
    }
    var detail: String {
        let feedback: String? = status.connected
            ? (status.ownsOutput && status.submissionID != latestSubmissionID
                ? "Sending latest snapshot. \(status.feedback.output?.summary ?? "Waiting for display status")."
                : status.feedback.detail) : nil
        return [status.message, status.outputIssue, feedback, status.connected ? status.templateCapabilities.policyDetail : nil, pairingNote].compactMap { $0 }.joined(separator: "\n")
    }

    func selectTemplate(_ template: AltViewContentTemplate?) {
        guard template?.isValid ?? true else { return }
        selectedTemplate = template
        onConfigurationChanged(.template(template))
    }

    func startDiscovery() { discovery.request(visibleDiscoveryID, needed: true) }
    func stopDiscovery() { discovery.request(visibleDiscoveryID, needed: false) }
    private func refreshDiscovery() {
        discovery.request(discoveryID, needed: isEnabled && destination?.receiverIdentity != nil)
    }
    func receiveDiscovered(_ receivers: [AltViewDestination], notice: String?) {
        guard isEnabled, let id = destination?.receiverIdentity,
              let fresh = receivers.first(where: { $0.receiverIdentity == id && $0.isValid }) else { return }
        destination = fresh
        if startedSender, let connectionID { sender.updateEndpoint(fresh.endpoint, connectionID: connectionID) }
        else { startSenderIfReady() }
    }
    func connect(to destination: AltViewDestination, code: String) {
        guard destination.isValid else { pairingNote = "Enter a host name and a port from 1 to 65535."; return }
        let enteredCode = !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let parsed = AltViewPairingKey.parse(code)
        guard !enteredCode || parsed != nil else { pairingNote = "Enter the eight-character pairing code shown in AltView."; return }
        if let issue = validateReceiver(destination, destination.receiverIdentity) { pairingNote = issue; return }
        disconnect()
        self.destination = destination
        let id = UUID()
        connectionID = id; isEnabled = true; pairingNote = nil
        refreshDiscovery()
        status = AltViewSenderStatus(connectionID: id, message: "Preparing connection…")
        let remembered = pairings[destination.account]
        connectionTask = Task { [weak self, store] in
            var pairing = remembered
            if parsed == nil, pairing == nil {
                do { pairing = try await store.read(account: destination.account) }
                catch {
                    guard let self, !Task.isCancelled, self.connectionID == id else { return }
                    self.status = AltViewSenderStatus(connectionID: id,
                        message: "Could not read the saved pairing from Keychain. Unlock Keychain and try Connect Only again, or enter the pairing code. \(error.localizedDescription)",
                        failureReason: "Saved pairing unavailable")
                    self.publicationIntent = nil
                    return
                }
            }
            guard let self, !Task.isCancelled, self.connectionID == id else { return }
            guard let key = parsed ?? pairing?.key else {
                self.status = AltViewSenderStatus(connectionID: id, message: "Enter the pairing code shown in AltView.", failureReason: "Pairing code required")
                self.publicationIntent = nil
                return
            }
            if parsed == nil, let saved = pairing?.receiverID, let expected = destination.receiverIdentity, saved != expected {
                self.status = AltViewSenderStatus(connectionID: id, message: "Saved receiver identity differs. Enter the receiver’s pairing code again.", failureReason: "Receiver identity changed")
                self.publicationIntent = nil; return
            }
            let receiverID = destination.receiverIdentity ?? (parsed == nil ? pairing?.receiverID : nil)
            if let issue = self.validateReceiver(destination, receiverID) {
                self.status = AltViewSenderStatus(connectionID: id, message: issue, failureReason: "Receiver already assigned")
                self.publicationIntent = nil
                return
            }
            self.pendingKey = key
            self.pendingReceiverID = receiverID
            self.startSenderIfReady()
        }
    }
    private func startSenderIfReady() {
        guard !startedSender, isEnabled, let connectionID, let key = pendingKey, var destination else { return }
        if let id = destination.receiverIdentity, destination.localReceiverID != nil || destination.host == nil {
            guard let fresh = receivers.first(where: { $0.receiverIdentity == id && $0.isValid }) else {
                status = AltViewSenderStatus(connectionID: connectionID, waitingToRetry: true,
                                            message: "Waiting to discover the selected AltView receiver. Open AltView and resume connections.")
                return
            }
            destination = fresh
            self.destination = fresh
        }
        startedSender = true
        sender.connect(to: destination.endpoint, key: key, expectedReceiverID: pendingReceiverID, connectionID: connectionID)
        if publicationIntent != nil { submit() }
    }
    func disconnect() {
        connectionTask?.cancel(); connectionTask = nil
        connectionID = nil; publicationIntent = nil; pendingKey = nil; pendingReceiverID = nil; savedConnectionID = nil
        if startedSender { sender.disconnect() }
        startedSender = false; identityValidated = false; isEnabled = false
        status = AltViewSenderStatus(); pairingNote = nil; latestSubmissionID = nil
        refreshDiscovery()
    }
    func publish(_ projection: PreparedProjection, blanked: Bool, explicit: Bool) {
        let data = projection.data
        // Background translation refreshes retain the published choice, like Blank and reconnect.
        let template = explicit ? selectedTemplate : currentContent?.template
        let secondary: AltViewConfidenceTranslation? = data.secondaryText.flatMap { text in
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != "\u{200c}" else { return nil }
            return AltViewConfidenceTranslation(body: text, footer: data.secondaryTranslationName ?? "")
        }
        // Audience stays primary-only; Confidence carries both committed translations.
        currentContent = AltViewDisplayContent(title: data.title, body: data.primaryText,
                                              footer: data.primaryTranslationName, visible: !blanked, template: template,
                                              confidence: AltViewConfidenceText(title: data.title, body: data.primaryText,
                                                  footer: data.primaryTranslationName, secondary: secondary))
        guard connectionID != nil, status.failureReason == nil else { return }
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
        guard let connectionID, startedSender, identityValidated else { return }
        let submission = AltViewSubmission(connectionID: connectionID, content: currentContent, intent: publicationIntent)
        latestSubmissionID = submission.id
        sender.submit(submission)
    }
    private func receive(_ status: AltViewSenderStatus) {
        guard let connectionID, status.connectionID == connectionID else { return }
        if status.connected, !identityValidated, let destination, let receiverID = status.receiverID {
            if let issue = validateReceiver(destination, receiverID) {
                disconnect()
                pairingNote = issue
                return
            }
            identityValidated = true
        }
        self.status = status
        if status.connected, publicationIntent != nil, latestSubmissionID == nil { submit() }
        if status.failureReason != nil { publicationIntent = nil }
        guard status.connected, savedConnectionID != connectionID,
              let receiverID = status.receiverID, let key = pendingKey, let destination else { return }
        savedConnectionID = connectionID
        var stable = destination; stable.receiverID = receiverID
        self.destination = stable
        refreshDiscovery()
        let pairing = AltViewPairing(key: key, receiverID: receiverID)
        pairings[stable.account] = pairing
        onConfigurationChanged(.paired(stable, receiverID))
        Task { [weak self, store] in
            do { try await store.save(pairing, account: stable.account) }
            catch {
                guard let self, self.connectionID == connectionID else { return }
                self.pairingNote = "Connected for this session. Pairing could not be saved in Keychain; enter the code again after restarting."
            }
        }
    }
}
