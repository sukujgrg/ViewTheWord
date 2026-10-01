// Adapted from AltView’s protocol v2 implementation (2026-10-02).
import Foundation

enum AltViewProtocol {
    static let version = 2
    static let serviceType = "_altview._tcp"
    static let maximumFrameSize = 65_536
    static let maximumClients = 8
    static let heartbeatInterval: TimeInterval = 1
    // Initial setup may need Bonjour resolution and macOS Local Network consent.
    static let connectionTimeout: TimeInterval = 30
    static let connectionAttemptTimeout: TimeInterval = 10
    static let timeout: TimeInterval = 5
}

enum AltViewEmptyRegionBehavior: String, Codable, Sendable { case collapse, reserve }

struct AltViewDisplayContent: Codable, Equatable, Sendable {
    var title = ""
    var body = ""
    var footer = ""
    var visible = true
    var emptyRegions = AltViewEmptyRegionBehavior.collapse

    var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasFooter: Bool { !footer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static let empty = AltViewDisplayContent(visible: false)

    var isValid: Bool {
        title.utf8.count <= 512 && body.utf8.count <= 24_000 && footer.utf8.count <= 1_024
    }
}

extension AltViewDisplayContent {
    private enum CodingKeys: String, CodingKey { case title, body, footer, visible, emptyRegions }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Each snapshot replaces the previous one: omitted labels clear them.
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try values.decode(String.self, forKey: .body)
        footer = try values.decodeIfPresent(String.self, forKey: .footer) ?? ""
        visible = try values.decode(Bool.self, forKey: .visible)
        emptyRegions = try values.decodeIfPresent(AltViewEmptyRegionBehavior.self, forKey: .emptyRegions) ?? .collapse
    }
}

/// Every state message is a complete snapshot. All optional fields are validated
/// by the receiver before use. Unknown message types cannot change output.
struct AltViewWireMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello, welcome, take, resume, granted, state, ownership, release, heartbeat, error, feedback
    }
    var version = AltViewProtocol.version
    var kind: Kind
    var senderID: UUID?
    var name: String?
    var receiverID: UUID?
    var lease: UUID?
    var revision: UInt64?
    var content: AltViewDisplayContent?
    var ownerID: UUID?
    var ownerName: String?
    var detail: String?
    var outputReadiness: AltViewOutputReadiness?
}

enum AltViewProtocolFailure: Error, LocalizedError {
    case invalidFrame, invalidContent, overloaded
    var errorDescription: String? {
        switch self {
        case .invalidFrame: return "The peer sent an invalid or oversized message."
        case .invalidContent: return "Content exceeds AltView’s text limits."
        case .overloaded: return "The connection cannot keep up with control messages."
        }
    }
}

enum AltViewFrameCodec {
    static func encode(_ message: AltViewWireMessage) throws -> Data {
        let data = try JSONEncoder().encode(message)
        guard !data.isEmpty, data.count <= AltViewProtocol.maximumFrameSize else { throw AltViewProtocolFailure.invalidFrame }
        var length = UInt32(data.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(data)
        return framed
    }
}

struct AltViewFrameDecoder {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [AltViewWireMessage] {
        buffer.append(data)
        var messages: [AltViewWireMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= AltViewProtocol.maximumFrameSize else { throw AltViewProtocolFailure.invalidFrame }
            guard buffer.count >= length + 4 else { break }
            messages.append(try JSONDecoder().decode(AltViewWireMessage.self, from: buffer.dropFirst(4).prefix(length)))
            buffer.removeFirst(length + 4)
        }
        return messages
    }
}

/// A slow socket retains one latest snapshot, one feedback message, one heartbeat, and a bounded set
/// of controls. It never accumulates a history of text updates.
struct AltViewMessageOutbox {
    private var controls: [AltViewWireMessage] = []
    private(set) var latestState: AltViewWireMessage?
    private var feedback: AltViewWireMessage?
    private var heartbeat: AltViewWireMessage?
    var count: Int { controls.count + (latestState == nil ? 0 : 1) + (heartbeat == nil ? 0 : 1) + (feedback == nil ? 0 : 1) }
    mutating func enqueue(_ message: AltViewWireMessage) throws {
        switch message.kind {
        case .state: latestState = message
        case .feedback: feedback = message
        case .heartbeat: heartbeat = message
        default:
            guard controls.count < 16 else { throw AltViewProtocolFailure.overloaded }
            controls.append(message)
        }
    }
    mutating func next() -> AltViewWireMessage? {
        if !controls.isEmpty { return controls.removeFirst() }
        if let state = latestState { latestState = nil; return state }
        if let message = feedback { feedback = nil; return message }
        defer { heartbeat = nil }
        return heartbeat
    }
    mutating func clearState() { latestState = nil }
}

extension AltViewWireMessage {
    var isValidReceiverMessage: Bool {
        guard version == AltViewProtocol.version else { return false }
        let validOwner = (ownerID == nil && ownerName == nil)
            || (ownerID != nil && ownerName.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 128 } == true)
        switch kind {
        case .welcome: return receiverID != nil && validOwner
        case .granted: return lease != nil
        case .ownership: return validOwner && ((ownerID == nil) == (lease == nil))
        case .feedback: return outputReadiness != nil && ((lease == nil && revision == nil) || (lease != nil && revision.map { $0 > 0 } == true))
        case .heartbeat, .error: return true
        default: return false
        }
    }
}

/// Software output availability, independent of snapshot acceptance or HDMI delivery.
enum AltViewOutputReadiness: String, Codable, Sendable {
    case closed, ready, preview, displayMissing, minimized, unavailable, asleep

    var summary: String {
        switch self {
        case .closed: return "Output window closed"
        case .ready: return "Output window open"
        case .preview: return "Preview window only"
        case .displayMissing: return "Output display disconnected"
        case .minimized: return "Output window minimized"
        case .unavailable: return "Output unavailable — check artwork in AltView"
        case .asleep: return "Receiver display asleep"
        }
    }
}

/// Queue-confined, bounded feedback. Missing acknowledgements never gate publication.
struct AltViewDeliveryFeedback: Equatable, Sendable {
    private(set) var output: AltViewOutputReadiness?
    private(set) var sentRevision: UInt64 = 0
    private(set) var acceptedRevision: UInt64 = 0
    private(set) var overdue = false
    private var pendingSince: TimeInterval?
    var accepted: Bool { sentRevision > 0 && acceptedRevision == sentRevision }

    var detail: String {
        let snapshot = sentRevision == 0 ? "No snapshot sent"
            : accepted ? "Latest snapshot accepted by AltView"
            : overdue ? "Snapshot acknowledgement delayed; sending continues"
            : "Waiting for snapshot acknowledgement"
        return "\(snapshot). \(output?.summary ?? "Waiting for display status")."
    }
    mutating func resetSnapshot() {
        sentRevision = 0; acceptedRevision = 0; pendingSince = nil; overdue = false
    }
    mutating func sent(_ revision: UInt64, now: TimeInterval) {
        sentRevision = revision
        if pendingSince == nil { pendingSince = now }
    }
    mutating func receive(_ message: AltViewWireMessage, lease: UUID?, now: TimeInterval) {
        guard message.kind == .feedback, let output = message.outputReadiness else { return }
        self.output = output
        // A delayed response from a previous owner/lease can never confirm current text.
        guard let lease, message.lease == lease, let revision = message.revision,
              revision > acceptedRevision, revision <= sentRevision else { return }
        acceptedRevision = revision
        pendingSince = accepted ? nil : now
        overdue = false
    }
    @discardableResult
    mutating func checkTimeout(now: TimeInterval) -> Bool {
        let value = pendingSince.map { now - $0 >= AltViewProtocol.timeout } ?? false
        guard value != overdue else { return false }
        overdue = value
        return true
    }
}
