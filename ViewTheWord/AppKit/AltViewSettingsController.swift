import AppKit
import Combine

@MainActor
final class AltViewSettingsController: NSViewController, NSTextFieldDelegate {
    let receiverPicker = NSPopUpButton()
    let hostField = NSTextField()
    let portField = NSTextField(string: "49721")
    let codeField = NSSecureTextField()
    let connectButton = NSButton(title: "Connect Only", target: nil, action: nil)
    let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    let statusBadge = AltViewStatusBadge()
    let statusLabel = NSTextField(wrappingLabelWithString: "Not connected")
    private let service: AltViewProjectionService
    private var receivers: [AltViewDestination] = []
    private var selected: AltViewDestination?
    private var discoveryNote: String?
    private var subscription: AnyCancellable?
    var discoveryEnabled = true
    private lazy var discovery = AltViewReceiverDiscovery { [weak self] receivers, error in
        MainActor.assumeIsolated { self?.applyReceivers(receivers, error: error) }
    }

    init(service: AltViewProjectionService) {
        self.service = service
        self.selected = service.destination?.host == nil ? service.destination : nil
        super.init(nibName: nil, bundle: nil)
        hostField.stringValue = service.destination?.host ?? ""
        portField.stringValue = String(service.destination?.port ?? 49721)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let explanation = NSTextField(wrappingLabelWithString: "Send the primary translation to AltView on another Mac. If its verse is missing, send the secondary translation.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        receiverPicker.target = self; receiverPicker.action = #selector(destinationChanged(_:))
        receiverPicker.setAccessibilityLabel("AltView receiver")
        hostField.placeholderString = "Receiving Mac name or IP address"
        hostField.setAccessibilityLabel("AltView host")
        portField.setAccessibilityLabel("AltView port")
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        codeField.placeholderString = "8-character code, or leave empty to use saved pairing"
        codeField.setAccessibilityLabel("AltView pairing code")
        for field in [hostField, portField, codeField] { field.delegate = self }
        for button in [connectButton, disconnectButton] { button.target = self; button.bezelStyle = .rounded }
        connectButton.action = #selector(connect(_:)); disconnectButton.action = #selector(disconnect(_:))
        let hint = NSTextField(wrappingLabelWithString: "Connecting leaves output unchanged. Project a verse to send it; Blank and Stop follow ViewTheWord. Appearance and display are set in AltView.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityLabel("AltView status")
        let actions = horizontalStack([connectButton, disconnectButton, NSView(), statusBadge])
        let stack = NSStackView(views: [explanation, row("Receiver", receiverPicker),
                                      row("Address", horizontalStack([hostField, portField])),
                                      row("Pairing code", codeField), actions, statusLabel, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        applyReceivers([], error: nil)
        subscription = service.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.render() }
        }
        render()
    }
    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = nativeLabel(title)
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        return horizontalStack([label, control], spacing: 12)
    }
    override func viewWillAppear() { super.viewWillAppear(); startDiscovery(); render() }
    override func viewWillDisappear() { super.viewWillDisappear(); stopDiscovery() }
    func startDiscovery() { if discoveryEnabled { discovery.start() } }
    func stopDiscovery() { discovery.stop() }
    private func applyReceivers(_ discovered: [AltViewDiscoveredReceiver], error: String?) {
        discoveryNote = error
        receivers = discovered.compactMap(AltViewDestination.init)
        if let selected, !receivers.contains(selected) { receivers.insert(selected, at: 0) }
        receiverPicker.removeAllItems()
        receiverPicker.addItem(withTitle: "Manual address")
        for (index, receiver) in receivers.enumerated() {
            let item = NSMenuItem(title: receiver.name, action: nil, keyEquivalent: "")
            item.tag = index + 1
            receiverPicker.menu?.addItem(item)
        }
        receiverPicker.selectItem(at: selected.flatMap { receivers.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        render()
    }
    private func render() {
        guard isViewLoaded else { return }
        hostField.isEnabled = selected == nil; portField.isEnabled = selected == nil
        disconnectButton.isEnabled = service.isEnabled
        disconnectButton.title = service.isEnabled && !service.status.connected && service.status.failureReason == nil ? "Cancel" : "Disconnect"
        connectButton.isEnabled = !service.isEnabled || service.status.failureReason != nil
        statusBadge.render(service)
        statusLabel.stringValue = service.detail + (discoveryNote.map { "\n\($0)" } ?? "")
        statusLabel.toolTip = statusLabel.stringValue
        if service.status.connected { codeField.stringValue = "" }
    }
    @objc private func destinationChanged(_ sender: Any?) {
        let index = receiverPicker.indexOfSelectedItem - 1
        selected = receivers.indices.contains(index) ? receivers[index] : nil
        service.disconnect(); codeField.stringValue = ""
        render()
    }
    func controlTextDidChange(_ obj: Notification) {
        // Changing destination/code cancels setup and invalidates delayed callbacks.
        if service.isEnabled { service.disconnect() }
        render()
    }
    @objc private func connect(_ sender: Any?) {
        let destination: AltViewDestination
        if let selected { destination = selected }
        else {
            guard let port = UInt16(portField.stringValue), port > 0 else {
                statusLabel.stringValue = "Enter a port from 1 to 65535."; return
            }
            let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            destination = AltViewDestination(name: host, host: host, port: port)
        }
        service.connect(to: destination, code: codeField.stringValue)
        render()
    }
    @objc private func disconnect(_ sender: Any?) { service.disconnect(); render() }
}
