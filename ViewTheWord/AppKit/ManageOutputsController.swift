import AppKit
import Combine

/// The single native destination and reusable-profile editor, embedded in Settings.
@MainActor
final class ManageOutputsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let live: LiveProjectionController
    var displays: ProjectionDisplayManager { live.projectionDisplays }
    let table = NSTableView()
    let section = NSSegmentedControl(labels: ["Outputs", "Profiles"], trackingMode: .selectOne, target: nil, action: nil)
    let monitorPicker = NSPopUpButton()
    let profilePicker = NSPopUpButton()
    let nameField = NSTextField()
    let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    let standbyClockButton = NSButton(checkboxWithTitle: "Show clock when empty or blanked", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let detailHost = NSView()
    private let addNative = NSButton(title: "Add Native", target: nil, action: nil)
    private let addRemote = NSButton(title: "Add AltView", target: nil, action: nil)
    private let remove = NSButton(title: "Remove", target: nil, action: nil)
    let addProfileButton = NSButton(image: NSImage(named: NSImage.addTemplateName)!, target: nil, action: nil)
    private let profileActions = NSStackView()
    private var isReloadingTable = false
    private var formIssue: String?
    private struct MonitorEntry: Equatable {
        var title: String
        var target: ProjectionMonitorTarget?
        var enabled: Bool
    }
    private var monitorEntries: [MonitorEntry] = []
    private var profileEntries: [String] = []
    private let closeButton = NSButton(title: "Close This Output", target: nil, action: nil)
    private let identifyButton = NSButton(title: "Identify", target: nil, action: nil)
    private let monitorNameButton = NSButton(title: "Name Monitor…", target: nil, action: nil)
    private var selectedID: UUID?
    private enum DetailKey: Equatable { case output(UUID), profile(UUID), empty }
    private var detailKey: DetailKey?
    private var selectedDetailKey: DetailKey {
        guard let selectedID else { return .empty }
        return profilesMode ? .profile(selectedID) : .output(selectedID)
    }
    private struct NameEdit { let destinationID: UUID; var text: String }
    private var nameEdit: NameEdit?
    private var child: NSViewController?
    private var subscriptions = Set<AnyCancellable>()
    private var reloadTask: Task<Void, Never>?
    var discoveryEnabled = true
    var remoteEditor: AltViewDestinationEditor? { child as? AltViewDestinationEditor }
    var profileEditor: OutputProfileEditor? { child as? OutputProfileEditor }
    private var profilesMode: Bool { section.selectedSegment == 1 }
    private var identifiers: [UUID] { profilesMode ? live.outputs.profiles.map(\.id) : live.outputs.destinations.map(\.id) }

    init(live: LiveProjectionController) {
        self.live = live
        super.init(nibName: nil, bundle: nil)
        for publisher in [live.outputs.objectWillChange, live.objectWillChange, displays.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleReload() }.store(in: &subscriptions)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { reloadTask?.cancel() }
    override func loadView() {
        view = NSView()
        section.selectedSegment = 0; section.target = self; section.action = #selector(changeSection(_:))
        table.addTableColumn(NSTableColumn(identifier: .init("outputs")))
        table.headerView = nil; table.style = .sourceList; table.rowHeight = 48
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = false
        table.setAccessibilityLabel("Outputs and profiles")
        let list = NSScrollView(); list.hasVerticalScroller = true; list.documentView = table
        list.borderType = .bezelBorder
        for (button, action) in [(addNative, #selector(addNativeOutput(_:))), (addRemote, #selector(addAltViewOutput(_:))), (remove, #selector(removeOutput(_:)))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded; button.controlSize = .small
        }
        addProfileButton.target = self; addProfileButton.action = #selector(addProfile(_:))
        addProfileButton.bezelStyle = .smallSquare; addProfileButton.controlSize = .small
        addProfileButton.toolTip = "Create a profile from the selected profile."
        addProfileButton.setAccessibilityLabel("Add profile")
        NSLayoutConstraint.activate([addProfileButton.widthAnchor.constraint(equalToConstant: 28),
                                     addProfileButton.heightAnchor.constraint(equalToConstant: 24)])
        profileActions.addArrangedSubview(addProfileButton); profileActions.addArrangedSubview(NSView())
        profileActions.orientation = .horizontal; profileActions.alignment = .centerY; profileActions.spacing = 0
        // This row detaches in Outputs mode. Keep its own dimensions so its
        // hit area survives reattachment instead of losing parent constraints.
        let sidebarWidth: CGFloat = 180
        NSLayoutConstraint.activate([profileActions.widthAnchor.constraint(equalToConstant: sidebarWidth),
                                     profileActions.heightAnchor.constraint(equalToConstant: 24)])
        let sidebar = NSStackView(views: [section, list, profileActions, addNative, addRemote, remove])
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 8
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebar); detailHost.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(detailHost)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sidebar.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16), sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth),
            detailHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            detailHost.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            detailHost.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            detailHost.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        for item in sidebar.arrangedSubviews where item !== profileActions { item.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true }
        nameField.delegate = self; nameField.setAccessibilityLabel("Output name")
        enabledButton.target = self; enabledButton.action = #selector(enabledChanged(_:))
        monitorPicker.target = self; monitorPicker.action = #selector(monitorChanged(_:))
        monitorPicker.setAccessibilityLabel("Monitor assignment"); monitorPicker.autoenablesItems = false
        profilePicker.target = self; profilePicker.action = #selector(profileChanged(_:)); profilePicker.setAccessibilityLabel("Appearance profile")
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor
        validationLabel.font = .systemFont(ofSize: 12); validationLabel.textColor = .systemOrange
        reload()
    }
    override func viewWillAppear() { super.viewWillAppear(); displays.refresh(); reload() }
    override func viewWillDisappear() { super.viewWillDisappear(); remoteEditor?.stopDiscovery() }
    func startDiscovery() { remoteEditor?.startDiscovery() }
    func stopDiscovery() { remoteEditor?.stopDiscovery() }
    private func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            await Task.yield(); guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil; self.reload()
        }
    }
    func reload() {
        guard isViewLoaded else { return }
        if selectedID == nil || !identifiers.contains(selectedID!) { formIssue = nil; selectedID = identifiers.first }
        isReloadingTable = true
        table.reloadData()
        if let id = selectedID, let index = identifiers.firstIndex(of: id) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        isReloadingTable = false
        addNative.isHidden = profilesMode; addRemote.isHidden = profilesMode; remove.isHidden = profilesMode
        profileActions.isHidden = !profilesMode
        addProfileButton.isEnabled = profilesMode && selectedID != nil && live.outputs.canEdit
        addNative.isEnabled = live.outputs.canEdit; addRemote.isEnabled = live.outputs.canEdit
        remove.isEnabled = selectedID != nil && live.outputs.canEdit
        if detailKey != selectedDetailKey { buildDetail() }
        renderDestination()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { identifiers.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = identifiers[row]
        let title: String; let subtitle: String
        if profilesMode { title = live.outputs.profile(id)?.name ?? ""; subtitle = "Reusable appearance" }
        else {
            let output = live.outputs.destination(id)!
            title = output.name
            subtitle = (output.native != nil ? "Native" : "AltView") + (output.enabled ? " · Enabled" : " · Disabled")
        }
        let label = nativeLabel(title, weight: .medium); let detail = nativeLabel(subtitle, size: 11); detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [label, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        let cell = NSTableCellView(); cell.textField = label; pin(stack, to: cell, inset: 6)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloadingTable, identifiers.indices.contains(table.selectedRow) else { return }
        let id = identifiers[table.selectedRow]
        if selectedID != id { endNameEditing(); formIssue = nil; selectedID = id; reload() }
    }
    func selectDestination(_ id: UUID) { section.selectedSegment = 0; select(id) }
    func selectProfile(_ id: UUID) { section.selectedSegment = 1; select(id) }
    private func select(_ id: UUID) { endNameEditing(); formIssue = nil; selectedID = id; detailKey = nil; reload() }
    private func endNameEditing() {
        if nameField.currentEditor() != nil || profileEditor?.nameField.currentEditor() != nil { view.window?.makeFirstResponder(nil) }
    }
    private func buildDetail() {
        detailKey = selectedDetailKey
        remoteEditor?.stopDiscovery()
        child?.removeFromParent(); child = nil
        for subview in detailHost.subviews { subview.removeFromSuperview() }
        if let notice = live.outputs.recoveryNotice {
            let label = NSTextField(wrappingLabelWithString: notice)
            let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
            let stack = NSStackView(views: [label, restore]); stack.orientation = .vertical; stack.alignment = .leading
            pin(stack, to: detailHost, inset: 12); return
        }
        guard let id = selectedID else { pin(nativeLabel("Add an output to get started."), to: detailHost); return }
        if profilesMode {
            let editor = OutputProfileEditor(store: live.outputs, profileID: id)
            editor.onStandbyChanged = { [weak live] enabled in
                live?.refreshPreferences()
                if enabled { live?.showStandbyOutputs(using: id) }
            }
            child = editor; addChild(editor); pin(editor.view, to: detailHost); return
        }
        guard let output = live.outputs.destination(id) else { return }
        let heading = nativeLabel(output.native == nil ? "AltView output" : "Native output", weight: .semibold)
        let stack = NSStackView(views: [heading, outputRow("Name", nameField), validationLabel, enabledButton])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        if output.native != nil {
            stack.addArrangedSubview(outputRow("Monitor", monitorPicker)); stack.addArrangedSubview(outputRow("Profile", profilePicker))
            let edit = NSButton(title: "Edit Profile…", target: self, action: #selector(editProfile(_:)))
            identifyButton.target = self; identifyButton.action = #selector(identifyMonitor(_:))
            monitorNameButton.target = self; monitorNameButton.action = #selector(nameMonitor(_:))
            stack.addArrangedSubview(horizontalStack([edit, identifyButton, monitorNameButton]))
            stack.addArrangedSubview(statusLabel)
            standbyClockButton.target = self; standbyClockButton.action = #selector(standbyClockChanged(_:))
            standbyClockButton.toolTip = "Applies to every native output using the selected profile."
            stack.addArrangedSubview(standbyClockButton)
            closeButton.target = self; closeButton.action = #selector(closeOutput(_:)); stack.addArrangedSubview(closeButton)
            let hint = NSTextField(wrappingLabelWithString: "All outputs follow the committed passage. The clock setting belongs to the selected profile. Close this output before changing its monitor. Missing monitors retain their assignments and require explicit reopening.")
            hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor; stack.addArrangedSubview(hint)
        } else if let service = live.altViewServices[id] {
            let editor = AltViewDestinationEditor(service: service, assignment: output.altView); editor.discoveryEnabled = discoveryEnabled
            editor.onConnect = { [weak live] receiver, code in live?.connectAltView(id, to: receiver, code: code) }
            editor.onSelectReceiver = { [weak live] receiver in
                guard let live, var saved = live.outputs.destination(id), var assignment = saved.altView else { return "Output no longer exists." }
                assignment.receiver = receiver; assignment.receiverID = receiver?.receiverIdentity
                saved.assignment = .altView(assignment); return live.outputs.update(saved)
            }
            child = editor; addChild(editor); stack.addArrangedSubview(editor.view)
            editor.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
            if view.window?.isVisible == true { editor.startDiscovery() }
        }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = OutputEditorDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        pin(scroll, to: detailHost)
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        for item in stack.arrangedSubviews { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    private func renderDestination() {
        guard !profilesMode, let id = selectedID, let output = live.outputs.destination(id) else { return }
        if nameField.currentEditor() == nil { nameField.stringValue = output.name }
        validationLabel.stringValue = formIssue ?? ""; validationLabel.isHidden = formIssue == nil
        enabledButton.state = output.enabled ? .on : .off
        guard let assignment = output.native else { return }
        var entries = [MonitorEntry(title: "None", target: nil, enabled: true)]
        let connected = displays.displays.map(\.target)
        var targets = connected + displays.knownTargets.filter { target in !connected.contains { $0.identity == target.identity } }
        if let target = assignment.monitor, !targets.contains(where: { $0.identity == target.identity }) { targets.append(target) }
        for target in targets {
            var candidate = output; candidate.assignment = .native(.init(monitor: target, profileID: assignment.profileID))
            entries.append(MonitorEntry(title: displays.label(for: target) + (displays.resolve(target) == nil ? " · Unavailable" : ""),
                target: target, enabled: displays.problem(for: target) == nil && live.outputs.conflict(for: candidate) == nil))
        }
        if entries != monitorEntries {
            monitorEntries = entries; monitorPicker.removeAllItems()
            for entry in entries {
                monitorPicker.addItem(withTitle: entry.title)
                monitorPicker.lastItem?.representedObject = entry.target; monitorPicker.lastItem?.isEnabled = entry.enabled
            }
        }
        if assignment.monitor == nil { monitorPicker.selectItem(at: 0) }
        if let item = monitorPicker.itemArray.first(where: { ($0.representedObject as? ProjectionMonitorTarget)?.identity == assignment.monitor?.identity }), assignment.monitor != nil { monitorPicker.select(item) }
        monitorPicker.isEnabled = live.nativeOutputs[id] == nil
        let profileEntries = live.outputs.profiles.map { $0.id.uuidString + ":" + $0.name }
        if profileEntries != self.profileEntries {
            self.profileEntries = profileEntries; profilePicker.removeAllItems()
            // addItem(withTitle:) replaces an existing title. Profile identity,
            // including copies with the same name, must remain selectable.
            for profile in live.outputs.profiles {
                let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
                item.representedObject = profile.id; profilePicker.menu?.addItem(item)
            }
        }
        profilePicker.select(profilePicker.itemArray.first { $0.representedObject as? UUID == assignment.profileID })
        let showsClock = live.outputs.profile(assignment.profileID)?.standby == .clock
        standbyClockButton.state = showsClock ? .on : .off
        standbyClockButton.isEnabled = live.outputs.canEdit
        closeButton.isEnabled = live.nativeOutputs[id] != nil
        identifyButton.isEnabled = assignment.monitor.map(displays.canIdentify) ?? false
        monitorNameButton.isEnabled = assignment.monitor.map(displays.canRename) ?? false
        statusLabel.stringValue = live.outputs.conflict(for: output) ?? assignment.monitor.flatMap { displays.problem(for: $0) }
            ?? (assignment.monitor == nil ? "Choose a monitor, or keep None to leave this output unassigned."
                : !output.enabled ? "Enable this output to use its assigned monitor."
                : live.nativeOutputs[id] != nil ? (showsClock && (live.projector.projection == nil || live.projector.isBlanked)
                    ? "Clock standby." : "Output open. Its appearance follows this profile.")
                : showsClock && (live.projector.projection == nil || live.projector.isBlanked)
                    ? "Re-enable this output to reopen its clock, or project a passage."
                    : "Project a passage to open this output.")
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === nameField, !profilesMode, let selectedID else { return }
        nameEdit = NameEdit(destinationID: selectedID, text: nameField.stringValue)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === nameField else { return }
        nameEdit?.text = nameField.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === nameField, let edit = nameEdit else { return }
        nameEdit = nil
        guard var output = live.outputs.destination(edit.destinationID) else { return }
        // The same NSTextField is reused as selection changes. Its visible value
        // may already belong to another output when the old editor ends.
        let text = selectedID == edit.destinationID && !profilesMode ? nameField.stringValue : edit.text
        output.name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let issue = live.outputs.update(output)
        if selectedID == edit.destinationID && !profilesMode {
            formIssue = issue
            // AppKit can retain currentEditor during the end notification, so
            // renderDestination's active-draft guard cannot restore this value.
            nameField.stringValue = live.outputs.destination(edit.destinationID)?.name ?? output.name
        }
        reload()
    }
    @objc private func changeSection(_ sender: Any?) { endNameEditing(); formIssue = nil; selectedID = nil; detailKey = nil; reload() }
    @objc private func addNativeOutput(_ sender: Any?) { selectDestination(live.outputs.addNative()) }
    @objc private func addAltViewOutput(_ sender: Any?) { selectDestination(live.outputs.addAltView()) }
    @objc private func addProfile(_ sender: Any?) {
        guard profilesMode, let selectedID else { return }
        endNameEditing()
        if let id = live.outputs.duplicateProfile(selectedID) { selectProfile(id) }
    }
    @objc private func removeOutput(_ sender: Any?) { if let id = selectedID { endNameEditing(); live.outputs.remove(id); live.refreshPreferences(); selectedID = nil; detailKey = nil; reload() } }
    @objc private func enabledChanged(_ sender: Any?) {
        guard var output = selectedID.flatMap(live.outputs.destination) else { return }
        output.enabled = enabledButton.state == .on
        formIssue = live.outputs.update(output); live.refreshPreferences(); reload()
        if formIssue == nil, output.enabled { live.showStandby(output.id); reload() }
    }
    @objc private func monitorChanged(_ sender: Any?) {
        guard var output = selectedID.flatMap(live.outputs.destination), var assignment = output.native else { return }
        assignment.monitor = monitorPicker.selectedItem?.representedObject as? ProjectionMonitorTarget
        output.assignment = .native(assignment)
        formIssue = live.outputs.update(output); live.refreshPreferences()
        if formIssue == nil { live.showStandby(output.id) }
        reload()
    }
    @objc private func profileChanged(_ sender: Any?) {
        guard var output = selectedID.flatMap(live.outputs.destination), var assignment = output.native,
              let id = profilePicker.selectedItem?.representedObject as? UUID else { return }
        assignment.profileID = id; output.assignment = .native(assignment); formIssue = live.outputs.update(output)
        live.refreshPreferences()
        if formIssue == nil { live.showStandby(output.id) }
        detailKey = nil; reload()
    }
    @objc private func standbyClockChanged(_ sender: NSButton) {
        guard let id = selectedID.flatMap(live.outputs.destination)?.native?.profileID,
              var profile = live.outputs.profile(id) else { return }
        profile.standby = sender.state == .on ? .clock : .hidden
        live.outputs.updateProfile(profile); live.refreshPreferences()
        if profile.standby == .clock { live.showStandbyOutputs(using: id) }
        reload()
    }
    @objc private func editProfile(_ sender: Any?) { if let id = selectedID.flatMap(live.outputs.destination)?.native?.profileID { selectProfile(id) } }
    @objc private func identifyMonitor(_ sender: Any?) { if let target = selectedID.flatMap(live.outputs.destination)?.native?.monitor { displays.identify(target) } }
    @objc private func nameMonitor(_ sender: Any?) {
        guard let target = selectedID.flatMap(live.outputs.destination)?.native?.monitor, let parent = view.window, parent.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 440, height: 310), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; sheet.contentViewController = ProjectionMonitorNameController(displays: displays, target: target)
        parent.beginSheet(sheet) { _ in sheet.orderOut(nil) }
    }
    @objc private func closeOutput(_ sender: Any?) { if let id = selectedID { live.closeNativeOutput(id); reload() } }
    @objc private func restoreDefaults(_ sender: Any?) { live.outputs.restoreDefaults(); selectedID = nil; detailKey = nil; reload() }
}

@MainActor
final class OutputEditorDocumentView: NSView { override var isFlipped: Bool { true } }

@MainActor
func outputRow(_ title: String, _ control: NSView) -> NSView {
    let label = nativeLabel(title); label.widthAnchor.constraint(equalToConstant: 112).isActive = true
    return horizontalStack([label, control], spacing: 12)
}
