import AppKit

@MainActor
func nativeLabel(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: size, weight: weight)
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

@MainActor
func horizontalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

@MainActor
func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}

@MainActor
func separator() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    return box
}

/// Fill the cross axis explicitly. `.width` is not a valid NSStackView alignment.
/// Restore these constraints when AppKit reattaches a previously hidden row.
@MainActor
final class WorkspaceColumnStack: NSStackView, NSStackViewDelegate {
    private var widths: [ObjectIdentifier: NSLayoutConstraint] = [:]
    init(content: [NSView]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        distribution = .fill
        spacing = 0
        delegate = self
        for child in content {
            addArrangedSubview(child)
            let constraint = child.widthAnchor.constraint(equalTo: widthAnchor)
            widths[ObjectIdentifier(child)] = constraint
            constraint.isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func stackView(_ stackView: NSStackView, willDetach views: [NSView]) {
        for view in views { widths[ObjectIdentifier(view)]?.isActive = false }
    }
    func stackView(_ stackView: NSStackView, didReattach views: [NSView]) {
        for view in views { widths[ObjectIdentifier(view)]?.isActive = true }
    }
}

@MainActor
final class WorkspacePaneController: NSViewController {
    let titleLabel: NSTextField
    let content: NSView
    let accessory: NSView?
    init(title: String, content: NSView, accessory: NSView? = nil, heading: NSTextField? = nil) {
        titleLabel = heading ?? nativeLabel(title, size: 12, weight: .semibold)
        self.content = content
        self.accessory = accessory
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let header = horizontalStack([titleLabel, NSView()] + (accessory.map { [$0] } ?? []))
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        let stack = WorkspaceColumnStack(content: [header, separator(), content])
        header.setContentHuggingPriority(.required, for: .vertical)
        pin(stack, to: view)
    }
}

@MainActor
final class WorkspaceMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}

extension NSMenu {
    @MainActor @discardableResult
    func command(_ title: String, checked: Bool = false, enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = WorkspaceMenuItem(title, checked: checked, enabled: enabled, action: action)
        addItem(item)
        return item
    }
    @MainActor func submenu(_ title: String, build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        build(menu)
        item.submenu = menu
        addItem(item)
    }
}
