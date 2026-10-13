import AppKit

@MainActor
final class ProjectionMonitorNameController: NSViewController, NSTextFieldDelegate {
    private let displays: ProjectionDisplayManager
    private let monitor: ProjectionMonitorTarget
    let name = NSTextField()
    let disclosure = NSButton(title: "▸ Monitor Details", target: nil, action: nil)
    let details = NSStackView()
    private let save = NSButton(title: "Save Name", target: nil, action: nil)
    private let error = NSTextField(wrappingLabelWithString: "")

    init(displays: ProjectionDisplayManager, target: ProjectionMonitorTarget) {
        self.displays = displays
        monitor = target
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        name.stringValue = displays.nickname(for: monitor)
        name.placeholderString = "Front Left TV"
        name.delegate = self
        name.setAccessibilityIdentifier("projectionMonitorName")
        let explanation = NSTextField(wrappingLabelWithString: "Use up to 40 characters on one line. Leave empty to use the model name.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        disclosure.isBordered = false
        disclosure.alignment = .left
        disclosure.target = self
        disclosure.action = #selector(toggleDetails(_:))
        disclosure.setAccessibilityIdentifier("projectionMonitorDetails")
        disclosure.setAccessibilityValue("Collapsed")
        let identity = NSTextField(wrappingLabelWithString: monitor.identity)
        identity.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        identity.isSelectable = true
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 4
        for label in [nativeLabel(monitor.name), nativeLabel("macOS display UUID"), identity] { details.addArrangedSubview(label) }
        details.isHidden = true
        error.font = .systemFont(ofSize: 12)
        error.textColor = .systemOrange
        let stack = NSStackView(views: [nativeLabel("Name \(displays.label(for: monitor))", weight: .semibold), name, explanation, disclosure, details, error])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelName(_:)))
        cancel.keyEquivalent = "\u{1b}"
        save.target = self
        save.action = #selector(saveName(_:))
        save.keyEquivalent = "\r"
        let actions = NSStackView(views: [cancel, save])
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actions)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 440), view.heightAnchor.constraint(equalToConstant: 310),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: actions.topAnchor, constant: -12)
        ])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    override func viewDidAppear() { super.viewDidAppear(); view.window?.makeFirstResponder(name) }
    func controlTextDidChange(_ notification: Notification) {
        save.isEnabled = ProjectionDisplayManager.normalizedName(name.stringValue) != nil && displays.canRename(monitor)
    }
    @objc func toggleDetails(_ sender: Any?) {
        details.isHidden.toggle()
        disclosure.title = "\(details.isHidden ? "▸" : "▾") Monitor Details"
        disclosure.setAccessibilityValue(details.isHidden ? "Collapsed" : "Expanded")
    }
    @objc private func cancelName(_ sender: Any?) { endSheet(.cancel) }
    @objc private func saveName(_ sender: Any?) {
        if displays.rename(monitor, to: name.stringValue) { endSheet(.OK) }
        else { error.stringValue = "Use a valid name for a distinguishable monitor." }
    }
    private func endSheet(_ response: NSApplication.ModalResponse) {
        if let sheet = view.window { sheet.sheetParent?.endSheet(sheet, returnCode: response) }
    }
}
