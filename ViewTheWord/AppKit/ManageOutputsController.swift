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
    let defaultButton = NSButton(title: "Make Default", target: nil, action: nil)
    let standbyClockButton = NSButton(checkboxWithTitle: "Show clock when empty or blanked", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let detailHost = NSView()
    let addOutputButton: NSPopUpButton
    let removeOutputButton = NSButton(image: NSImage(named: NSImage.removeTemplateName)!, target: nil, action: nil)
    private let outputActions = NSStackView()
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
    private let editProfileButton = NSButton(title: "Edit Profile…", target: nil, action: nil)
    private let clearBackgroundButton = NSButton(title: "Clear Background", target: nil, action: nil)
    private let identifyButton = NSButton(title: "Identify", target: nil, action: nil)
    private let monitorNameButton = NSButton(title: "Name Monitor…", target: nil, action: nil)
    private var selectedID: UUID?
    private enum DetailKey: Equatable { case native(UUID), remote(UUID, ObjectIdentifier?), profile(UUID), empty, recovery(String) }
    private var detailKey: DetailKey?
    private var selectedDetailKey: DetailKey {
        if let notice = live.outputs.recoveryNotice { return .recovery(notice) }
        guard let selectedID else { return .empty }
        if profilesMode { return .profile(selectedID) }
        return live.outputs.destination(selectedID)?.native != nil ? .native(selectedID)
            : .remote(selectedID, live.altViewServices[selectedID].map(ObjectIdentifier.init))
    }
    private struct NameEdit { let destinationID: UUID; var text: String }
    private var nameEdit: NameEdit?
    private var child: NSViewController?
    private var reusableProfileEditor: OutputProfileEditor?
    private struct RemoteEditor {
        let service: AltViewProjectionService
        let editor: AltViewDestinationEditor
    }
    private var remoteEditors: [UUID: RemoteEditor] = [:]
    private var destinationForm: NSView?
    private let destinationHeading = nativeLabel(weight: .semibold)
    private let nativeBody = NSStackView()
    private let remoteHost = NSView()
    private var nativeBodyBuilt = false
    private struct ListRow: Equatable { let id: UUID; let title: String; let subtitle: String; var isDefault = false }
    private var listRows: [ListRow] = []
    private var listSection = -1
    private var updatesEnabled = true
    private struct NativeInput: Equatable {
        let output: OutputDestination
        let configuration: OutputConfiguration
        let displayRevision: Int
        let openOutputs: Set<UUID>
        let hasScripture: Bool
        let blanked: Bool
        let issue: String?
    }
    private var nativeInput: NativeInput?
    private var subscriptions = Set<AnyCancellable>()
    private var reloadTask: Task<Void, Never>?
    var discoveryEnabled = true
    var remoteEditor: AltViewDestinationEditor? { child as? AltViewDestinationEditor }
    var profileEditor: OutputProfileEditor? { child as? OutputProfileEditor }
    private var profilesMode: Bool { section.selectedSegment == 1 }
    private var editedDestination: OutputDestination? {
        guard updatesEnabled, !profilesMode else { return nil }
        return selectedID.flatMap(live.outputs.destination)
    }
    private var identifiers: [UUID] { profilesMode ? live.outputs.profiles.map(\.id) : live.outputs.destinations.map(\.id) }

    init(live: LiveProjectionController) {
        self.live = live
        let addMenu = NSMenu(title: "Add output"); addMenu.autoenablesItems = false
        addMenu.addItem(withTitle: "Native Output", action: #selector(addNativeOutput(_:)), keyEquivalent: "")
        addMenu.addItem(withTitle: "AltView Output", action: #selector(addAltViewOutput(_:)), keyEquivalent: "")
        addOutputButton = NSPopUpButton(image: NSImage(named: NSImage.addTemplateName)!, pullDownMenu: addMenu)
        super.init(nibName: nil, bundle: nil)
        for item in addMenu.items { item.target = self }
        for publisher in [live.outputs.objectWillChange, live.objectWillChange, displays.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleReload() }.store(in: &subscriptions)
        }
        // Deletions invalidate cached UUID-bound callbacks even with Settings
        // hidden. Status-only notifications never enter this path.
        live.outputs.$configuration.sink { [weak self] configuration in
            self?.discardRemoteEditors(except: configuration)
        }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { reloadTask?.cancel() }
    override func loadView() {
        view = NSView()
        section.selectedSegment = 0; section.target = self; section.action = #selector(changeSection(_:))
        table.addTableColumn(NSTableColumn(identifier: .init("outputs")))
        table.headerView = nil; table.style = .sourceList; table.rowHeight = 48
        table.focusRingType = .none
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = false
        table.setAccessibilityLabel("Outputs and profiles")
        let list = NSScrollView(); list.hasVerticalScroller = true; list.documentView = table
        list.borderType = .bezelBorder; list.focusRingType = .none
        addOutputButton.autoenablesItems = false
        addOutputButton.setAccessibilityLabel("Add output"); addOutputButton.toolTip = "Add a native monitor output or an AltView output."
        removeOutputButton.target = self; removeOutputButton.action = #selector(removeOutput(_:))
        removeOutputButton.setAccessibilityLabel("Remove output"); removeOutputButton.toolTip = "Remove the selected output."
        defaultButton.target = self; defaultButton.action = #selector(makeDefault(_:))
        for button in [addOutputButton, removeOutputButton, defaultButton, addProfileButton] {
            button.bezelStyle = .rounded; button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let creationActions = horizontalStack([addOutputButton, removeOutputButton], spacing: 4)
        for item in [creationActions, NSView(), defaultButton] { outputActions.addArrangedSubview(item) }
        outputActions.orientation = .horizontal; outputActions.alignment = .centerY; outputActions.spacing = 8
        addProfileButton.target = self; addProfileButton.action = #selector(addProfile(_:))
        addProfileButton.toolTip = "Create a profile from the selected profile."
        addProfileButton.setAccessibilityLabel("Add profile")
        profileActions.addArrangedSubview(addProfileButton); profileActions.addArrangedSubview(NSView())
        profileActions.orientation = .horizontal; profileActions.alignment = .centerY; profileActions.spacing = 0
        // This row detaches in Outputs mode. Keep its own dimensions so its
        // hit area survives reattachment instead of losing parent constraints.
        let sidebarWidth: CGFloat = 200
        for actions in [outputActions, profileActions] {
            NSLayoutConstraint.activate([actions.widthAnchor.constraint(equalToConstant: sidebarWidth),
                                         actions.heightAnchor.constraint(equalToConstant: 24)])
        }
        let listGroup = NSStackView(views: [list, outputActions, profileActions])
        listGroup.orientation = .vertical; listGroup.alignment = .leading; listGroup.spacing = 4
        for item in [list, outputActions, profileActions] { item.widthAnchor.constraint(equalTo: listGroup.widthAnchor).isActive = true }
        let sidebar = NSStackView(views: [section, listGroup])
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
        for item in sidebar.arrangedSubviews { item.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true }
        nameField.delegate = self; nameField.setAccessibilityLabel("Output name")
        enabledButton.target = self; enabledButton.action = #selector(enabledChanged(_:))
        monitorPicker.target = self; monitorPicker.action = #selector(monitorChanged(_:))
        monitorPicker.setAccessibilityLabel("Monitor assignment"); monitorPicker.autoenablesItems = false
        profilePicker.target = self; profilePicker.action = #selector(profileChanged(_:)); profilePicker.setAccessibilityLabel("Appearance profile")
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor
        validationLabel.font = .systemFont(ofSize: 12); validationLabel.textColor = .systemOrange
        reload()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        if view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor { displays.refresh(); startDiscovery() }
    }
    override func viewWillDisappear() { super.viewWillDisappear(); stopDiscovery() }
    func startDiscovery() {
        updatesEnabled = true
        if let profileEditor { profileEditor.represent(profileEditor.profileID) }
        reload()
        remoteEditor?.setUIUpdatesEnabled(true)
        remoteEditor?.startDiscovery()
    }
    func stopDiscovery() {
        endNameEditing()
        updatesEnabled = false; reloadTask?.cancel(); reloadTask = nil; nativeInput = nil
        profileEditor?.deactivate()
        remoteEditor?.setUIUpdatesEnabled(false)
        remoteEditor?.stopDiscovery()
    }
    private func scheduleReload() {
        guard updatesEnabled, isViewLoaded, reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            await Task.yield(); guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil; self.reload()
        }
    }
    func reload() {
        guard isViewLoaded, updatesEnabled else { return }
        pruneRemoteEditors()
        if selectedID == nil || !identifiers.contains(selectedID!) { endNameEditing(); formIssue = nil; selectedID = identifiers.first }
        let rows = profilesMode ? live.outputs.profiles.map { ListRow(id: $0.id, title: $0.name, subtitle: "Reusable appearance") }
            : live.outputs.destinations.map { ListRow(id: $0.id, title: $0.name, subtitle: ($0.native != nil ? "Native" : "AltView") + ($0.enabled ? " · Enabled" : " · Disabled"), isDefault: $0.id == live.outputs.configuration.defaultDestinationID) }
        isReloadingTable = true
        if rows != listRows || listSection != section.selectedSegment {
            listRows = rows; listSection = section.selectedSegment; table.reloadData()
        }
        if let id = selectedID, let index = listRows.firstIndex(where: { $0.id == id }), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        isReloadingTable = false
        if outputActions.isHidden != profilesMode {
            outputActions.isHidden = profilesMode
        }
        if profileActions.isHidden != !profilesMode { profileActions.isHidden = !profilesMode }
        addProfileButton.isEnabled = profilesMode && selectedID != nil && live.outputs.canEdit
        addOutputButton.isEnabled = !profilesMode && live.outputs.canEdit
        for item in addOutputButton.itemArray { item.isEnabled = addOutputButton.isEnabled }
        removeOutputButton.isEnabled = editedDestination != nil && live.outputs.canEdit
        let isDefault = editedDestination?.id == live.outputs.configuration.defaultDestinationID && editedDestination != nil
        let defaultTitle = isDefault ? "Default" : "Make Default"
        if defaultButton.title != defaultTitle { defaultButton.title = defaultTitle }
        defaultButton.isEnabled = editedDestination != nil && !isDefault && live.outputs.canEdit
        defaultButton.toolTip = isDefault ? "This output is the default for the top-right controls."
            : "Make the selected output the default for the top-right controls without enabling it."
        defaultButton.setAccessibilityLabel(isDefault ? "Default output" : "Make selected output default")
        if detailKey != selectedDetailKey { buildDetail() }
        renderDestination()
        profileEditor?.refresh()
        if !profilesMode, let id = selectedID { remoteEditor?.updateAssignment(live.outputs.destination(id)?.altView) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { listRows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard listRows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("outputRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? OutputListCell ?? OutputListCell()
        cell.identifier = identifier
        cell.textField?.stringValue = listRows[row].title; cell.detail.stringValue = listRows[row].subtitle
        cell.defaultLabel.isHidden = !listRows[row].isDefault
        cell.setAccessibilityLabel(listRows[row].title + ", " + listRows[row].subtitle + (listRows[row].isDefault ? ", Default" : ""))
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloadingTable, listRows.indices.contains(table.selectedRow) else { return }
        let id = listRows[table.selectedRow].id
        if selectedID != id { endNameEditing(); formIssue = nil; selectedID = id; reload() }
    }
    func selectDestination(_ id: UUID) { section.selectedSegment = 0; select(id) }
    func selectProfile(_ id: UUID) { section.selectedSegment = 1; select(id) }
    private func select(_ id: UUID) { endNameEditing(); formIssue = nil; selectedID = id; reload() }
    private func endNameEditing() {
        let remoteFields = remoteEditor.map { [$0.hostField, $0.portField, $0.codeField] } ?? []
        if nameField.currentEditor() != nil || profileEditor?.nameField.currentEditor() != nil || remoteFields.contains(where: { $0.currentEditor() != nil }) {
            view.window?.makeFirstResponder(nil)
        }
        profileEditor?.finishNameEditing()
        if nameEdit != nil { controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: nameField)) }
    }
    private func pruneRemoteEditors() {
        for (id, cached) in remoteEditors where live.outputs.destination(id)?.altView == nil || live.altViewServices[id] !== cached.service {
            cached.editor.invalidate(); remoteEditors.removeValue(forKey: id)
        }
    }
    private func discardRemoteEditors(except configuration: OutputConfiguration) {
        for (id, cached) in remoteEditors where !configuration.destinations.contains(where: { $0.id == id && $0.altView != nil }) {
            cached.editor.invalidate()
            if child === cached.editor { child?.removeFromParent(); child = nil; detailKey = nil }
            if cached.editor.isViewLoaded, remoteHost.subviews.first === cached.editor.view { cached.editor.view.removeFromSuperview() }
            remoteEditors.removeValue(forKey: id)
        }
    }
    private func showDetail(_ content: NSView, controller: NSViewController? = nil) {
        if child !== controller {
            remoteEditor?.setUIUpdatesEnabled(false); remoteEditor?.stopDiscovery()
            profileEditor?.deactivate()
            child?.removeFromParent(); child = controller
            if let controller { addChild(controller) }
        }
        if content.superview !== detailHost {
            pin(content, to: detailHost)
        }
        // Keep the two reusable forms attached, preserving AppKit's solved
        // constraints and text sizes across section changes. Hidden forms have
        // no UI subscriptions or active editing callbacks.
        let retainForms = selectedID != nil && live.outputs.recoveryNotice == nil
        for subview in detailHost.subviews {
            if subview !== content && (!retainForms || (subview !== destinationForm && subview !== reusableProfileEditor?.view)) {
                subview.removeFromSuperview()
            } else if subview.isHidden != (subview !== content) { subview.isHidden = subview !== content }
        }
    }
    private func buildDetail() {
        detailKey = selectedDetailKey
        if let notice = live.outputs.recoveryNotice {
            let label = NSTextField(wrappingLabelWithString: notice)
            let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
            let stack = NSStackView(views: [label, restore]); stack.orientation = .vertical; stack.alignment = .leading
            showDetail(stack); return
        }
        guard let id = selectedID else {
            // The detail fills Settings. Pinning a label itself to all four
            // edges also makes its intrinsic height the pane's maximum height.
            let empty = NSView()
            let label = nativeLabel("Add an output to get started.")
            label.translatesAutoresizingMaskIntoConstraints = false
            empty.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: empty.leadingAnchor),
                label.topAnchor.constraint(equalTo: empty.topAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: empty.trailingAnchor)
            ])
            showDetail(empty); return
        }
        if profilesMode {
            let editor = reusableProfileEditor ?? OutputProfileEditor(store: live.outputs, profileID: id)
            reusableProfileEditor = editor
            editor.onStandbyChanged = { [weak live] profileID, enabled in
                live?.refreshPreferences()
                if enabled { live?.showStandbyOutputs(using: profileID) }
            }
            editor.represent(id)
            showDetail(editor.view, controller: editor); return
        }
        guard let output = live.outputs.destination(id) else { return }
        if destinationForm == nil { destinationForm = makeDestinationForm() }
        let heading = output.native == nil ? "AltView output" : "Native output"
        if destinationHeading.stringValue != heading { destinationHeading.stringValue = heading }
        if nativeBody.isHidden != (output.native == nil) { nativeBody.isHidden = output.native == nil }
        if remoteHost.isHidden != (output.native != nil) { remoteHost.isHidden = output.native != nil }
        if output.native != nil {
            if !nativeBodyBuilt { buildNativeBody(); nativeBodyBuilt = true }
            showDetail(destinationForm!)
        } else if let service = live.altViewServices[id] {
            let editor: AltViewDestinationEditor
            if let cached = remoteEditors[id], cached.service === service { editor = cached.editor }
            else {
                editor = AltViewDestinationEditor(service: service, assignment: output.altView); editor.discoveryEnabled = discoveryEnabled
                editor.onConnect = { [weak live, weak service] receiver, code in
                    guard let live, let service, live.altViewServices[id] === service else { return "Output no longer exists." }
                    return live.connectAltView(id, to: receiver, code: code)
                }
                editor.onSelectReceiver = { [weak live, weak service] receiver in
                    guard let live, let service, live.altViewServices[id] === service,
                          var saved = live.outputs.destination(id), var assignment = saved.altView else { return "Output no longer exists." }
                    assignment.receiver = receiver; assignment.receiverID = receiver?.receiverIdentity
                    saved.assignment = .altView(assignment); return live.outputs.update(saved)
                }
                editor.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
                remoteEditors[id] = RemoteEditor(service: service, editor: editor)
            }
            showDetail(destinationForm!, controller: editor)
            editor.updateAssignment(output.altView)
            if remoteHost.subviews.first !== editor.view {
                for subview in remoteHost.subviews { subview.removeFromSuperview() }
                pin(editor.view, to: remoteHost)
            }
            editor.setUIUpdatesEnabled(updatesEnabled)
            if view.window?.isVisible == true { editor.startDiscovery() }
        } else { showDetail(destinationForm!) }
    }
    private func makeDestinationForm() -> NSView {
        let stack = WorkspaceColumnStack(content: [destinationHeading, outputRow("Name", nameField), validationLabel, enabledButton, nativeBody, remoteHost])
        stack.spacing = 12
        nativeBody.orientation = .vertical; nativeBody.alignment = .leading; nativeBody.spacing = 12
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = OutputEditorDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        return scroll
    }
    private func buildNativeBody() {
        let stack = nativeBody
        editProfileButton.target = self; editProfileButton.action = #selector(editProfile(_:))
        clearBackgroundButton.target = self; clearBackgroundButton.action = #selector(clearBackground(_:))
        clearBackgroundButton.toolTip = "Make the background transparent for every native output using this profile."
        identifyButton.target = self; identifyButton.action = #selector(identifyMonitor(_:))
        monitorNameButton.target = self; monitorNameButton.action = #selector(nameMonitor(_:))
        stack.addArrangedSubview(pickerRow("Monitor", monitorPicker, actions: [identifyButton, monitorNameButton]))
        stack.addArrangedSubview(pickerRow("Profile", profilePicker, actions: [editProfileButton, clearBackgroundButton]))
        stack.addArrangedSubview(statusLabel)
        standbyClockButton.target = self; standbyClockButton.action = #selector(standbyClockChanged(_:))
        standbyClockButton.toolTip = "Applies to every native output using the selected profile."
        stack.addArrangedSubview(standbyClockButton)
        closeButton.target = self; closeButton.action = #selector(closeOutput(_:)); stack.addArrangedSubview(closeButton)
        let hint = NSTextField(wrappingLabelWithString: "All outputs follow the committed passage. The clock setting belongs to the selected profile. Close this output before changing its monitor. Missing monitors retain their assignments and require explicit reopening.")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor; stack.addArrangedSubview(hint)
        for item in stack.arrangedSubviews { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    private func pickerRow(_ title: String, _ picker: NSPopUpButton, actions: [NSButton]) -> NSView {
        for button in actions {
            button.bezelStyle = .rounded; button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        // Equal widths derive from the larger intrinsic button size. The
        // compact action group shares the picker's leading edge.
        let actionRow = horizontalStack(actions, spacing: 8)
        actions[0].widthAnchor.constraint(equalTo: actions[1].widthAnchor).isActive = true
        let group = NSStackView(views: [picker, actionRow])
        group.orientation = .vertical; group.alignment = .leading; group.spacing = 6
        picker.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        let row = outputRow(title, group)
        row.alignment = .top
        return row
    }
    private func renderDestination() {
        guard !profilesMode, let id = selectedID, let output = live.outputs.destination(id) else { return }
        if nameField.currentEditor() == nil, nameField.stringValue != output.name { nameField.stringValue = output.name }
        if validationLabel.stringValue != (formIssue ?? "") { validationLabel.stringValue = formIssue ?? "" }
        if validationLabel.isHidden != (formIssue == nil) { validationLabel.isHidden = formIssue == nil }
        if enabledButton.state != (output.enabled ? .on : .off) { enabledButton.state = output.enabled ? .on : .off }
        guard let assignment = output.native else { return }
        let input = NativeInput(output: output, configuration: live.outputs.configuration, displayRevision: displays.revision,
                                openOutputs: Set(live.nativeOutputs.keys), hasScripture: live.projector.projection != nil,
                                blanked: live.projector.isBlanked, issue: formIssue)
        guard input != nativeInput else { return }
        nativeInput = input
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
        editProfileButton.isEnabled = live.outputs.canEdit
        clearBackgroundButton.isEnabled = live.outputs.canEdit && live.outputs.profile(assignment.profileID)?.transparent == false
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
    @objc private func addNativeOutput(_ sender: Any?) {
        guard updatesEnabled, !profilesMode, live.outputs.canEdit else { return }
        endNameEditing(); selectDestination(live.outputs.addNative())
    }
    @objc private func addAltViewOutput(_ sender: Any?) {
        guard updatesEnabled, !profilesMode, live.outputs.canEdit else { return }
        endNameEditing()
        let id = live.outputs.addAltView()
        // The editor needs its service during this selection's first render.
        // Deferred preference refresh would leave an incomplete cached detail.
        live.refreshPreferences()
        selectDestination(id)
    }
    @objc private func addProfile(_ sender: Any?) {
        guard updatesEnabled, profilesMode, let selectedID else { return }
        endNameEditing()
        if let id = live.outputs.duplicateProfile(selectedID) { selectProfile(id) }
    }
    @objc private func removeOutput(_ sender: Any?) { if let id = editedDestination?.id { endNameEditing(); live.outputs.remove(id); live.refreshPreferences(); selectedID = nil; detailKey = nil; reload() } }
    @objc private func enabledChanged(_ sender: Any?) {
        guard var output = editedDestination else { return }
        output.enabled = enabledButton.state == .on
        formIssue = live.outputs.update(output); live.refreshPreferences(); reload()
        if formIssue == nil, output.enabled { live.showStandby(output.id); reload() }
    }
    @objc private func makeDefault(_ sender: Any?) {
        guard let output = editedDestination else { return }
        endNameEditing()
        live.outputs.setDefaultDestination(output.id)
        reload()
    }
    @objc private func monitorChanged(_ sender: Any?) {
        guard var output = editedDestination, var assignment = output.native else { return }
        assignment.monitor = monitorPicker.selectedItem?.representedObject as? ProjectionMonitorTarget
        output.assignment = .native(assignment)
        formIssue = live.outputs.update(output); live.refreshPreferences()
        if formIssue == nil { live.showStandby(output.id) }
        reload()
    }
    @objc private func profileChanged(_ sender: Any?) {
        guard var output = editedDestination, var assignment = output.native,
              let id = profilePicker.selectedItem?.representedObject as? UUID else { return }
        assignment.profileID = id; assignment.quickEditProfileID = nil
        output.assignment = .native(assignment); formIssue = live.outputs.update(output)
        live.refreshPreferences()
        if formIssue == nil { live.showStandby(output.id) }
        detailKey = nil; reload()
    }
    @objc private func standbyClockChanged(_ sender: NSButton) {
        guard let id = editedDestination?.native?.profileID,
              var profile = live.outputs.profile(id) else { return }
        profile.standby = sender.state == .on ? .clock : .hidden
        live.outputs.updateProfile(profile); live.refreshPreferences()
        if profile.standby == .clock { live.showStandbyOutputs(using: id) }
        reload()
    }
    @objc private func editProfile(_ sender: Any?) { if let id = editedDestination?.native?.profileID { selectProfile(id) } }
    @objc private func clearBackground(_ sender: Any?) {
        guard let id = editedDestination?.native?.profileID,
              var profile = live.outputs.profile(id) else { return }
        profile.transparent = true
        formIssue = live.outputs.updateProfile(profile)
        live.refreshPreferences(); reload()
    }
    @objc private func identifyMonitor(_ sender: Any?) { if let target = editedDestination?.native?.monitor { displays.identify(target) } }
    @objc private func nameMonitor(_ sender: Any?) {
        guard let target = editedDestination?.native?.monitor, let parent = view.window, parent.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 440, height: 310), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; sheet.contentViewController = ProjectionMonitorNameController(displays: displays, target: target)
        parent.beginSheet(sheet) { _ in sheet.orderOut(nil) }
    }
    @objc private func closeOutput(_ sender: Any?) { if let id = editedDestination?.id { live.closeNativeOutput(id); reload() } }
    @objc private func restoreDefaults(_ sender: Any?) { guard updatesEnabled else { return }; live.outputs.restoreDefaults(); selectedID = nil; detailKey = nil; reload() }
}

@MainActor
final class OutputEditorDocumentView: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class OutputListCell: NSTableCellView {
    let detail = nativeLabel(size: 11)
    let defaultLabel = nativeLabel("Default", size: 10, weight: .medium)
    init() {
        super.init(frame: .zero)
        let label = nativeLabel(weight: .medium)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.textColor = .secondaryLabelColor
        defaultLabel.textColor = .secondaryLabelColor
        defaultLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = horizontalStack([label, defaultLabel], spacing: 6)
        let stack = NSStackView(views: [heading, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        heading.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        textField = label; pin(stack, to: self, inset: 6)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
func outputRow(_ title: String, _ control: NSView) -> NSStackView {
    let label = nativeLabel(title); label.widthAnchor.constraint(equalToConstant: 112).isActive = true
    return horizontalStack([label, control], spacing: 12)
}
