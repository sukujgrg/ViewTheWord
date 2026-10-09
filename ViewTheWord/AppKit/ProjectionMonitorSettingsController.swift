import AppKit
import Combine

/// Uses the same assignment authority as the passage toolbar and live output.
@MainActor
final class ProjectionMonitorSettingsController: NSViewController {
    let displays: ProjectionDisplayManager
    let picker = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let monitorRows = NSStackView()
    private var subscription: AnyCancellable?

    init(displays: ProjectionDisplayManager) {
        self.displays = displays
        super.init(nibName: nil, bundle: nil)
        subscription = displays.$revision.sink { [weak self] _ in
            // Published values notify before mutation completes.
            Task { @MainActor [weak self] in self?.reload() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let document = ProjectionMonitorDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        picker.target = self
        picker.action = #selector(selectMonitor(_:))
        picker.setAccessibilityIdentifier("projectionMonitorPicker")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        monitorRows.orientation = .vertical
        monitorRows.alignment = .leading
        monitorRows.spacing = 14
        let explanation = NSTextField(wrappingLabelWithString: "Identify shows a monitor’s number and name for three seconds. Names and numbers are remembered, including disconnected monitors.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [nativeLabel("Projection monitor", weight: .semibold), picker, status,
                                        nativeLabel("Monitors", weight: .semibold), monitorRows, explanation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        reload()
    }
    override func viewWillAppear() { super.viewWillAppear(); displays.refresh(); reload() }

    func reload() {
        guard isViewLoaded else { return }
        picker.removeAllItems()
        if displays.target == nil {
            picker.addItem(withTitle: "Choose a monitor…")
            picker.lastItem?.isEnabled = false
        }
        picker.autoenablesItems = false
        for display in displays.displays {
            picker.addItem(withTitle: displays.label(for: display.target) + (display.isBuiltIn ? " · Built-in" : ""))
            picker.lastItem?.representedObject = display.target
            picker.lastItem?.isEnabled = displays.problem(for: display.target) == nil
        }
        if let target = displays.target, !displays.displays.contains(where: { $0.identity == target.identity }) {
            picker.addItem(withTitle: displays.label(for: target) + " · Unavailable")
            picker.lastItem?.representedObject = target
            picker.lastItem?.isEnabled = false
        }
        if let target = displays.target,
           let item = picker.itemArray.first(where: { ($0.representedObject as? ProjectionMonitorTarget)?.identity == target.identity }) {
            picker.select(item)
        }
        picker.isEnabled = !displays.isLocked && !displays.displays.isEmpty
        status.stringValue = displays.selectionProblem ?? (displays.isLocked
            ? "Stop projection before changing its monitor."
            : "Projection uses only the monitor you choose. Your selection is remembered.")
        for row in monitorRows.arrangedSubviews { monitorRows.removeArrangedSubview(row); row.removeFromSuperview() }
        let connected = displays.displays.map(\.target)
        let targets = connected + displays.knownTargets.filter { target in !connected.contains { $0.identity == target.identity } }
        for target in targets {
            let display = displays.displays.first { $0.identity == target.identity }
            let title = nativeLabel(displays.label(for: target), weight: .medium)
            let detail = NSTextField(wrappingLabelWithString: display.map {
                displays.problem(for: target) ?? "\($0.name) · \(Int($0.frame.width)) × \(Int($0.frame.height))"
            } ?? "Disconnected")
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 4
            text.translatesAutoresizingMaskIntoConstraints = false
            for label in [title, detail] {
                label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
            }
            let identify = MonitorActionButton(title: "Identify", targetMonitor: target)
            identify.target = self
            identify.action = #selector(identifyMonitor(_:))
            identify.isEnabled = displays.canIdentify(target)
            identify.toolTip = "Show this monitor’s number and name for three seconds"
            let name = MonitorActionButton(title: "Name…", targetMonitor: target)
            name.target = self
            name.action = #selector(nameMonitor(_:))
            name.isEnabled = displays.canRename(target)
            let row = NSView()
            for child in [text, identify, name] { row.addSubview(child) }
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                text.topAnchor.constraint(equalTo: row.topAnchor),
                text.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                identify.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 12),
                name.leadingAnchor.constraint(equalTo: identify.trailingAnchor, constant: 8),
                name.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                name.widthAnchor.constraint(equalTo: identify.widthAnchor),
                identify.centerYAnchor.constraint(equalTo: text.centerYAnchor),
                name.centerYAnchor.constraint(equalTo: text.centerYAnchor)
            ])
            monitorRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: monitorRows.widthAnchor).isActive = true
        }
        if targets.isEmpty { monitorRows.addArrangedSubview(nativeLabel("Connect a monitor to name and identify it.")) }
    }
    @objc private func selectMonitor(_ sender: NSPopUpButton) {
        if let target = sender.selectedItem?.representedObject as? ProjectionMonitorTarget { displays.select(target) }
        reload()
    }
    @objc private func identifyMonitor(_ sender: MonitorActionButton) { displays.identify(sender.targetMonitor) }
    @objc private func nameMonitor(_ sender: MonitorActionButton) {
        guard let parent = view.window, parent.attachedSheet == nil else { return }
        let editor = ProjectionMonitorNameController(displays: displays, target: sender.targetMonitor)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 310),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Monitor Name"
        sheet.isReleasedWhenClosed = false
        sheet.contentViewController = editor
        parent.beginSheet(sheet) { [weak self] _ in sheet.orderOut(nil); self?.reload() }
    }
}

@MainActor
private final class ProjectionMonitorDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class MonitorActionButton: NSButton {
    let targetMonitor: ProjectionMonitorTarget
    init(title: String, targetMonitor: ProjectionMonitorTarget) {
        self.targetMonitor = targetMonitor
        super.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryPushIn)
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

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
