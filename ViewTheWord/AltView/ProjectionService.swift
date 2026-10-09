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
    // A private choice until the next explicit projection. Empty saved value means receiver layout.
    @Published private(set) var selectedTemplate: AltViewContentTemplate? = .scripture
    @Published private(set) var receivers: [AltViewDestination] = []
    @Published private(set) var discoveryNote: String?
    private var discoveryVisible = false
    private var discoveryRunning = false
    private var discoveryRetryTask: Task<Void, Never>?
    private var discoveryRetryAttempt = 0
    private lazy var discovery: any AltViewDiscovering = discoveryFactory { [weak self] receivers, error in
        MainActor.assumeIsolated { self?.receiveDiscovered(receivers.compactMap(AltViewDestination.init), notice: error) }
    }
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
    private var didRestoreConnection = false
    private let defaults: UserDefaults
    private let store: any AltViewPairingStoring
    private let discoveryFactory: (@escaping ([AltViewDiscoveredReceiver], String?) -> Void) -> any AltViewDiscovering
    private let senderFactory: (@escaping @Sendable (AltViewSenderStatus) -> Void) -> any AltViewSending
    private lazy var sender: any AltViewSending = senderFactory { [weak self] status in
        MainActor.assumeIsolated { self?.receive(status) }
    }

    convenience init(defaults: UserDefaults = .standard, store: any AltViewPairingStoring = AltViewPairingStore(),
         senderFactory: @escaping (@escaping @Sendable (AltViewSenderStatus) -> Void) -> any AltViewSending = {
             AltViewSenderClient(name: "ViewTheWord · \(Host.current().localizedName ?? "Mac")", onStatus: $0)
         }) {
        self.init(defaults: defaults, store: store, discoveryFactory: { AltViewReceiverDiscovery(onChange: $0) },
                  senderFactory: senderFactory)
    }
    init(defaults: UserDefaults, store: any AltViewPairingStoring,
         discoveryFactory: @escaping (@escaping ([AltViewDiscoveredReceiver], String?) -> Void) -> any AltViewDiscovering,
         senderFactory: @escaping (@escaping @Sendable (AltViewSenderStatus) -> Void) -> any AltViewSending) {
        self.defaults = defaults; self.store = store; self.senderFactory = senderFactory; self.discoveryFactory = discoveryFactory
        if let saved = defaults.string(forKey: AppDefaultsKey.altViewTemplate) {
            let template = AltViewContentTemplate(rawValue: saved)
            if saved.isEmpty { selectedTemplate = nil }
            else if template.isValid { selectedTemplate = template }
        }
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
        defaults.set(template?.rawValue ?? "", forKey: AppDefaultsKey.altViewTemplate)
    }

    /// Called once at application launch, never by Settings or passage creation.
    /// Keychain loading uses its actor and the sender owns all network work.
    func restoreConnection() {
        guard !didRestoreConnection else { return }
        didRestoreConnection = true
        guard connectionID == nil, let destination else { return }
        connect(to: destination, code: "")
    }

    func startDiscovery() { discoveryVisible = true; refreshDiscovery() }
    func stopDiscovery() { discoveryVisible = false; refreshDiscovery() }
    private func refreshDiscovery() {
        let needed = discoveryVisible || (isEnabled && destination?.localReceiverID != nil)
        guard needed != discoveryRunning else { return }
        discoveryRunning = needed
        discoveryRetryTask?.cancel(); discoveryRetryTask = nil; discoveryRetryAttempt = 0
        // A restarted browser must resolve dynamic ports from its new inventory.
        receivers = []; discoveryNote = nil
        if needed { discovery.start() } else { discovery.stop() }
    }
    func receiveDiscovered(_ receivers: [AltViewDestination], notice: String?) {
        self.receivers = receivers; discoveryNote = notice
        discoveryRetryTask?.cancel(); discoveryRetryTask = nil
        if notice != nil, discoveryRunning { scheduleDiscoveryRetry() }
        else if notice == nil { discoveryRetryAttempt = 0 }
        guard isEnabled, let id = destination?.localReceiverID,
              let fresh = receivers.first(where: { $0.localReceiverID == id && $0.isValid }) else { return }
        destination = fresh
        if startedSender, let connectionID { sender.updateEndpoint(fresh.endpoint, connectionID: connectionID) }
        else { startSenderIfReady() }
    }
    private func scheduleDiscoveryRetry() {
        let delay = AltViewSenderClient.reconnectDelay(attempt: discoveryRetryAttempt)
        discoveryRetryAttempt = min(discoveryRetryAttempt + 1, 5)
        discoveryRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.discoveryRunning else { return }
            self.discoveryRetryTask = nil
            self.receivers = []
            self.discovery.stop()
            self.discovery.start()
        }
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
            self.pendingKey = key
            self.pendingReceiverID = (parsed == nil ? pairing?.receiverID : nil) ?? destination.localReceiverID
            self.startSenderIfReady()
        }
    }
    private func startSenderIfReady() {
        guard !startedSender, isEnabled, let connectionID, let key = pendingKey, var destination else { return }
        if let id = destination.localReceiverID {
            guard let fresh = receivers.first(where: { $0.localReceiverID == id && $0.isValid }) else {
                status = AltViewSenderStatus(connectionID: connectionID, waitingToRetry: true,
                                            message: "Waiting to discover AltView on This Mac. Open AltView and enable receiving.")
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
        didRestoreConnection = true
        connectionTask?.cancel(); connectionTask = nil
        connectionID = nil; publicationIntent = nil; pendingKey = nil; pendingReceiverID = nil; savedConnectionID = nil
        if startedSender { sender.disconnect() }
        startedSender = false; isEnabled = false
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
