import AppKit
import Combine

@MainActor
final class AltViewDestinationEditor: NSViewController, NSTextFieldDelegate {
    let receiverPicker = NSPopUpButton()
    let templatePicker = NSPopUpButton()
    let templateHint = NSTextField(wrappingLabelWithString: "")
    private var templateMenuEntries: [AltViewTemplateDescriptor]?
    private var unavailableTemplate: AltViewContentTemplate?
    let hostField = NSTextField()
    let portField = NSTextField()
    let codeField = NSSecureTextField()
    let connectButton = NSButton(title: "Connect Only", target: nil, action: nil)
    let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    let statusBadge = AltViewStatusBadge()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "Not connected")
    private let service: AltViewProjectionService
    private var receivers: [AltViewDestination] = []
    private var selected: AltViewDestination?
    private var usesThisMac: Bool
    private var subscription: AnyCancellable?
    private var renderTask: Task<Void, Never>?
    private var uiUpdatesEnabled = true
    private var isValid = true
    private var assignmentReceiver: AltViewDestination?
    var discoveryEnabled = true
    var onConnect: (AltViewDestination, String) -> String? = { _, _ in nil }
    var onSelectReceiver: (AltViewDestination?) -> String? = { _ in nil }


    init(service: AltViewProjectionService, assignment: AltViewOutputAssignment? = nil) {
        let receiver = assignment == nil ? service.destination : assignment?.receiver
        self.service = service
        onConnect = { receiver, code in service.connect(to: receiver, code: code); return nil }
        self.usesThisMac = receiver == nil || receiver?.localReceiverID != nil
        self.selected = receiver?.host == nil || receiver?.localReceiverID != nil ? receiver : nil
        assignmentReceiver = receiver
        super.init(nibName: nil, bundle: nil)
        hostField.stringValue = receiver?.host ?? ""
        portField.stringValue = receiver.flatMap { $0.host == nil ? nil : $0.port }.map(String.init) ?? ""
        portField.placeholderString = "Port"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { renderTask?.cancel() }
    override func loadView() {
        view = NSView()
        let explanation = NSTextField(wrappingLabelWithString: "Pair the AltView receiver once using its code from Connections. Enable this scripture output separately, then Project to send. Pairing never enables or takes output. AltView owns appearance and display assignments. Update all three apps together for protocol 3.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        receiverPicker.target = self; receiverPicker.action = #selector(destinationChanged(_:))
        receiverPicker.setAccessibilityLabel("AltView receiver")
        templatePicker.target = self; templatePicker.action = #selector(templateChanged(_:))
        templatePicker.setAccessibilityLabel("AltView template")
        templatePicker.menu?.autoenablesItems = false
        templateHint.font = .systemFont(ofSize: 11); templateHint.textColor = .secondaryLabelColor
        templateHint.maximumNumberOfLines = 0
        hostField.placeholderString = "Receiving Mac name or IP address"
        hostField.setAccessibilityLabel("AltView host")
        portField.setAccessibilityLabel("AltView port")
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        codeField.placeholderString = "8-character code, or leave empty to use saved pairing"
        codeField.setAccessibilityLabel("AltView pairing code")
        for field in [hostField, portField, codeField] { field.delegate = self }
        for button in [connectButton, disconnectButton] { button.target = self; button.bezelStyle = .rounded }
        connectButton.action = #selector(connect(_:)); disconnectButton.action = #selector(disconnect(_:))
        connectButton.keyEquivalent = "\r"
        let hint = NSTextField(wrappingLabelWithString: "Saved receivers connect automatically at startup and reconnect after a network drop. Project a verse to send it; Blank and Stop follow ViewTheWord. This Mac is the default for a new connection; its current port is discovered automatically. Saved receivers keep their selection. This does not restrict AltView’s LAN listener. Appearance and displays are set in AltView.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.setAccessibilityLabel("AltView status")
        validationLabel.textColor = .systemOrange; validationLabel.font = .systemFont(ofSize: 12)
        let actions = horizontalStack([connectButton, disconnectButton, NSView(), statusBadge])
        let stack = NSStackView(views: [explanation, row("Receiver", receiverPicker),
                                      row("Address", horizontalStack([hostField, portField])),
                                      row("Receiver code", codeField), actions, validationLabel, row("Layout", templatePicker), templateHint, statusLabel, hint])
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
        refreshReceivers()
        subscribe()
        render()
    }
    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = nativeLabel(title)
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        return horizontalStack([label, control], spacing: 12)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        if view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor { setUIUpdatesEnabled(true); startDiscovery() }
    }
    override func viewWillDisappear() { super.viewWillDisappear(); setUIUpdatesEnabled(false); stopDiscovery() }
    func startDiscovery() { if discoveryEnabled && isValid && uiUpdatesEnabled { service.startDiscovery() } }
    func stopDiscovery() { if discoveryEnabled { service.stopDiscovery() } }
    func setUIUpdatesEnabled(_ enabled: Bool) {
        let enabled = enabled && isValid
        guard uiUpdatesEnabled != enabled else { return }
        uiUpdatesEnabled = enabled
        if enabled { subscribe(); render() }
        else { subscription = nil; renderTask?.cancel(); renderTask = nil }
    }
    func invalidate() { setUIUpdatesEnabled(false); stopDiscovery(); isValid = false }
    private func subscribe() {
        guard uiUpdatesEnabled, isValid, subscription == nil, isViewLoaded else { return }
        subscription = service.objectWillChange.sink { [weak self] _ in
            guard let self, self.uiUpdatesEnabled, self.renderTask == nil else { return }
            self.renderTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled, self.uiUpdatesEnabled else { return }
                self.renderTask = nil; self.render()
            }
        }
    }
    func updateAssignment(_ assignment: AltViewOutputAssignment?) {
        guard assignmentReceiver != assignment?.receiver else { return }
        assignmentReceiver = assignment?.receiver
        let receiver = assignment?.receiver
        usesThisMac = receiver == nil || receiver?.localReceiverID != nil
        selected = receiver?.host == nil || receiver?.localReceiverID != nil ? receiver : nil
        hostField.stringValue = receiver?.host ?? ""
        portField.stringValue = receiver.flatMap { $0.host == nil ? nil : $0.port }.map(String.init) ?? ""
        codeField.stringValue = ""
        render()
    }
    private func refreshReceivers() {
        let discovered = service.receivers.filter { $0.isValid }
        if let id = selected?.localReceiverID,
           let fresh = discovered.first(where: { $0.localReceiverID == id }) { selected = fresh }
        // Resolve the initial default once, then retain its receiver identity.
        if usesThisMac, selected == nil {
            selected = discovered.first(where: { $0.localReceiverID != nil })
        }
        let local = usesThisMac ? selected : discovered.first(where: { $0.localReceiverID != nil })
        var freshReceivers = discovered.filter {
            $0.localReceiverID == nil || $0.localReceiverID != local?.localReceiverID
        }
        if !usesThisMac, let selected, !freshReceivers.contains(selected) { freshReceivers.insert(selected, at: 0) }
        // Status and acknowledgement updates must not replace an open menu.
        if receivers != freshReceivers || receiverPicker.numberOfItems == 0 {
            receivers = freshReceivers
            receiverPicker.removeAllItems()
            receiverPicker.addItems(withTitles: ["This Mac", "Manual address"])
            for (index, receiver) in receivers.enumerated() {
                let item = NSMenuItem(title: receiver.name, action: nil, keyEquivalent: "")
                item.tag = index + 2
                receiverPicker.menu?.addItem(item)
            }
        }
        let tip = local?.name ?? "Open AltView on this Mac to discover its current port."
        if receiverPicker.item(at: 0)?.toolTip != tip { receiverPicker.item(at: 0)?.toolTip = tip }
        let index = usesThisMac ? 0 : selected.flatMap { receivers.firstIndex(of: $0) }.map { $0 + 2 } ?? 1
        if receiverPicker.indexOfSelectedItem != index { receiverPicker.selectItem(at: index) }
    }
    private func render() {
        guard isViewLoaded, uiUpdatesEnabled, isValid else { return }
        refreshReceivers()
        let manual = !usesThisMac && selected == nil
        if hostField.isEnabled != manual { hostField.isEnabled = manual; portField.isEnabled = manual }
        let connecting = service.isEnabled && !service.status.connected && service.status.failureReason == nil
        let canDisconnect = service.status.connected || connecting
        if disconnectButton.isEnabled != canDisconnect { disconnectButton.isEnabled = canDisconnect }
        let title = connecting ? "Cancel" : "Disconnect"
        if disconnectButton.title != title { disconnectButton.title = title }
        let canConnect = (!service.isEnabled || service.status.failureReason != nil) && !(usesThisMac && selected == nil)
        if connectButton.isEnabled != canConnect { connectButton.isEnabled = canConnect }
        refreshTemplatePicker()
        statusBadge.render(service)
        let detail = usesThisMac && selected == nil && !service.isEnabled
            ? "Open AltView on this Mac. Its receiver will be selected automatically when discovered." : service.detail
        let text = detail + (service.discoveryNote.map { "\n\($0)" } ?? "")
        if statusLabel.stringValue != text { statusLabel.stringValue = text; statusLabel.toolTip = text }
        let color = AltViewStatusBadge.statusColor(for: service)
        if statusLabel.textColor != color { statusLabel.textColor = color }
        if service.status.connected, !codeField.stringValue.isEmpty { codeField.stringValue = "" }
    }
    private func refreshTemplatePicker() {
        let capabilities = service.status.templateCapabilities
        let entries = capabilities.templates ?? []
        let unavailable = service.selectedTemplate.flatMap { capabilities.supports($0) ? nil : $0 }
        // Routine acknowledgement/policy updates must not replace an open menu.
        if templateMenuEntries != entries || unavailableTemplate != unavailable {
            templateMenuEntries = entries; unavailableTemplate = unavailable
            templatePicker.removeAllItems()
            templatePicker.addItem(withTitle: "Receiver’s layout")
            for descriptor in entries {
                let item = NSMenuItem(title: descriptor.name, action: nil, keyEquivalent: "")
                item.representedObject = descriptor.id.rawValue
                templatePicker.menu?.addItem(item)
            }
            if let unavailable {
                let item = NSMenuItem(title: "\(unavailable.rawValue) · Unavailable", action: nil, keyEquivalent: "")
                item.representedObject = unavailable.rawValue
                item.isEnabled = false
                templatePicker.menu?.addItem(item)
            }
        }
        if let requested = service.selectedTemplate,
           let item = templatePicker.itemArray.first(where: { $0.representedObject as? String == requested.rawValue }) {
            if templatePicker.selectedItem !== item { templatePicker.select(item) }
        } else if templatePicker.indexOfSelectedItem != 0 { templatePicker.selectItem(at: 0) }
        if templatePicker.isEnabled != service.status.connected { templatePicker.isEnabled = service.status.connected }
        let detail = service.status.connected ? capabilities.requestDetail(service.selectedTemplate)
            : "Connect to discover the receiver’s templates."
        let hint = "\(detail) Changes apply when you next project a verse."
        if templateHint.stringValue != hint { templateHint.stringValue = hint; templateHint.toolTip = hint }
    }
    @objc private func templateChanged(_ sender: Any?) {
        guard isValid, uiUpdatesEnabled else { return }
        service.selectTemplate((templatePicker.selectedItem?.representedObject as? String).map(AltViewContentTemplate.init(rawValue:)))
        refreshTemplatePicker()
    }
    @objc private func destinationChanged(_ sender: Any?) {
        guard isValid, uiUpdatesEnabled else { return }
        let previous = selected, previousLocal = usesThisMac
        validationLabel.stringValue = ""
        usesThisMac = receiverPicker.indexOfSelectedItem == 0
        if usesThisMac {
            selected = selected?.localReceiverID != nil ? selected : service.receivers.first(where: { $0.localReceiverID != nil && $0.isValid })
        } else {
            let index = receiverPicker.indexOfSelectedItem - 2
            selected = receivers.indices.contains(index) ? receivers[index] : nil
        }
        if let issue = onSelectReceiver(selected) { selected = previous; usesThisMac = previousLocal; render(); validationLabel.stringValue = issue; return }
        assignmentReceiver = selected
        service.disconnect(); codeField.stringValue = ""
        render()
    }
    func controlTextDidChange(_ obj: Notification) {
        guard isValid, uiUpdatesEnabled else { return }
        // Changing destination/code cancels setup and invalidates delayed callbacks.
        if service.isEnabled { service.disconnect() }
        render()
    }
    @objc private func connect(_ sender: Any?) {
        guard isValid, uiUpdatesEnabled else { return }
        validationLabel.stringValue = ""
        let destination: AltViewDestination
        if let selected { destination = selected }
        else if usesThisMac { render(); return }
        else {
            guard let port = UInt16(portField.stringValue), port > 0 else {
                statusLabel.stringValue = "Enter a port from 1 to 65535."; statusLabel.textColor = .systemOrange; return
            }
            let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            destination = AltViewDestination(name: host, host: host, port: port)
        }
        if let issue = onConnect(destination, codeField.stringValue) { validationLabel.stringValue = issue; return }
        // This save came from our own fields. A subsequent configuration
        // notification must not reset their draft or clear the pairing code.
        assignmentReceiver = destination
        render()
    }
    @objc private func disconnect(_ sender: Any?) { guard isValid, uiUpdatesEnabled else { return }; service.disconnect(); render() }
}
