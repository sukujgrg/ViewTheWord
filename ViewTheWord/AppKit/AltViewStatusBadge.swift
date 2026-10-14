import AppKit

/// Passive connection status shared by the workspace footer and Settings.
/// Green means connected, independently of output ownership/readiness; warnings win.
@MainActor
final class AltViewStatusBadge: NSView {
    private let label = nativeLabel("AltView off", size: 11, weight: .medium)
    private var indicatorColor = NSColor.tertiaryLabelColor

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 21),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("AltView connection")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: size.width + 29, height: size.height + 6)
    }

    static func statusColor(for service: AltViewProjectionService) -> NSColor {
        if service.status.failureReason != nil || service.status.outputIssue != nil ||
            service.pairingNote != nil || service.discoveryNote != nil || service.status.feedback.overdue {
            return .systemOrange
        }
        return service.status.connected ? .systemGreen : .secondaryLabelColor
    }

    func render(_ service: AltViewProjectionService, showOutputStatus: Bool = false) {
        let connection: String
        if service.status.connected {
            connection = "AltView · Connected"
        } else if service.isEnabled {
            connection = service.status.waitingToRetry ? "AltView · Waiting to reconnect"
                : (service.status.failureReason == nil ? "AltView · Connecting" : "AltView · Unavailable")
        } else {
            connection = "AltView off"
        }
        label.textColor = Self.statusColor(for: service)
        indicatorColor = label.textColor ?? .secondaryLabelColor
        let hasOutputStatus = service.status.ownsOutput || service.status.ownerName != nil || service.status.outputIssue != nil
        label.stringValue = showOutputStatus && hasOutputStatus ? service.summary : connection
        toolTip = [connection, service.destination?.name, service.detail].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityValue(label.stringValue == connection ? connection : "\(connection). \(label.stringValue)")
        setAccessibilityHelp(toolTip)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func render(_ services: [AltViewProjectionService]) {
        if services.count == 1, let service = services.first { render(service, showOutputStatus: true); return }
        let connected = services.filter { $0.status.connected }.count
        label.stringValue = services.isEmpty ? "AltView off" : "AltView · \(connected) connected"
        let hasWarning = services.contains { Self.statusColor(for: $0) == .systemOrange }
        indicatorColor = hasWarning ? .systemOrange : connected > 0 ? .systemGreen : .secondaryLabelColor
        label.textColor = indicatorColor
        toolTip = services.map { [$0.destination?.name, $0.summary, $0.detail].compactMap { $0 }.joined(separator: "\n") }.joined(separator: "\n\n")
        setAccessibilityValue(label.stringValue); setAccessibilityHelp(toolTip)
        invalidateIntrinsicContentSize(); needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        indicatorColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        indicatorColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: (bounds.height - 7) / 2, width: 7, height: 7)).fill()
    }
}
