import AppKit

/// Passive connection status shared by the workspace footer and Settings.
/// Green means the paired receiver is connected, independently of its output.
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

    func render(_ service: AltViewProjectionService, showOutputStatus: Bool = false) {
        let connection: String
        if service.status.connected {
            connection = "AltView · Connected"
            indicatorColor = .systemGreen
        } else if service.isEnabled {
            connection = service.status.failureReason == nil ? "AltView · Connecting" : "AltView · Unavailable"
            indicatorColor = .systemOrange
        } else {
            connection = "AltView off"
            indicatorColor = .tertiaryLabelColor
        }
        let hasOutputStatus = service.status.ownsOutput || service.status.ownerName != nil || service.status.outputIssue != nil
        label.stringValue = showOutputStatus && hasOutputStatus ? service.summary : connection
        toolTip = [connection, service.destination?.name, service.detail].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityValue(label.stringValue == connection ? connection : "\(connection). \(label.stringValue)")
        setAccessibilityHelp(toolTip)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        indicatorColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        indicatorColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: (bounds.height - 7) / 2, width: 7, height: 7)).fill()
    }
}
