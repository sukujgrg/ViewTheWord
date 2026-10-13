import AppKit
import Combine
import UniformTypeIdentifiers

/// All library sheets belong to the window so switching panes cannot dismiss a decision.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let settings: NativeSettingsController
    private let library: BibleLibrary
    private var alertSubscription: AnyCancellable?
    private var presentationTask: Task<Void, Never>?
    private var presentingSheet = false

    init(library: BibleLibrary? = nil, liveProjection: LiveProjectionController? = nil) {
        let library = library ?? liveProjection?.library ?? .shared
        self.library = library
        settings = NativeSettingsController(library: library, liveProjection: liveProjection ?? LiveProjectionController(library: library))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.tabbingMode = .disallowed
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.contentViewController = settings
        window.setContentSize(NSSize(width: 820, height: 650))
        window.contentMinSize = NSSize(width: 780, height: 580)
        window.center()
        super.init(window: window)
        window.delegate = self
        settings.bibleLibrary.onImport = { [weak self] in self?.importBible() }
        settings.bibleLibrary.onRemove = { [weak self] url in self?.removeBible(url) }
        alertSubscription = library.$alerts.sink { [weak self] _ in self?.scheduleAlertPresentation() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { presentationTask?.cancel() }

    override func showWindow(_ sender: Any?) {
        library.setSettingsPresented(true)
        settings.outputs.reload()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        if settings.selectedTabViewItemIndex == 0 { settings.outputs.startDiscovery() }
        scheduleAlertPresentation()
    }
    func windowDidBecomeKey(_ notification: Notification) { scheduleAlertPresentation() }
    func windowWillClose(_ notification: Notification) {
        settings.outputs.stopDiscovery()
        library.setSettingsPresented(false)
        if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .cancel) }
    }

    private func importBible() {
        guard !presentingSheet, !library.isImporting, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Bible"
        panel.prompt = "Import"
        panel.allowedContentTypes = [UTType(exportedAs: "com.viewtheword.sqlite3.database", conformingTo: .database), .database]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        presentingSheet = true
        panel.beginSheetModal(for: window) { [weak self, library] response in
            if response == .OK {
                // The library retains security-scoped access before the panel releases its URLs.
                for url in panel.urls { library.importFile(url, presenter: .settings) }
            }
            self?.didEndSheet()
        }
    }

    private func removeBible(_ url: URL) {
        guard !presentingSheet, !library.isImporting, library.isImported(url),
              let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Remove imported translation?"
        alert.informativeText = "\(BibleTranslation.name(for: url)) will be moved to Trash. A selected translation will fall back to an available Bible."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        presentingSheet = true
        alert.beginSheetModal(for: window) { [weak self, library] response in
            if response == .alertFirstButtonReturn { library.removeImported(url) }
            self?.didEndSheet()
        }
    }

    private func didEndSheet() {
        presentingSheet = false
        scheduleAlertPresentation()
    }
    private func scheduleAlertPresentation() {
        guard presentationTask == nil else { return }
        presentationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.presentationTask = nil
            self.presentAlertIfNeeded()
        }
    }
    private func presentAlertIfNeeded() {
        guard !presentingSheet, let window, window.isVisible, window.isKeyWindow, window.attachedSheet == nil,
              let request = library.claimAlert(for: .settings) else { return }
        presentingSheet = true
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.message
        let replacing: Bool
        if case .replacement = request.content {
            replacing = true
            alert.addButton(withTitle: "Replace Translation")
            alert.addButton(withTitle: "Cancel")
        } else {
            replacing = false
            alert.addButton(withTitle: "OK")
        }
        alert.beginSheetModal(for: window) { [weak self, library] response in
            library.completeAlert(request.id, replaceExisting: replacing && response == .alertFirstButtonReturn)
            self?.didEndSheet()
        }
    }
}

@MainActor
final class NativeSettingsController: NSTabViewController {
    let outputs: ManageOutputsController
    let bibleLibrary: BibleLibrarySettingsController
    init(library: BibleLibrary, liveProjection: LiveProjectionController) {
        outputs = ManageOutputsController(live: liveProjection)
        bibleLibrary = BibleLibrarySettingsController(library: library)
        super.init(nibName: nil, bundle: nil)
        title = "Settings"; tabStyle = .toolbar; transitionOptions = []
        for (controller, label, symbol) in [(outputs as NSViewController, "Manage Outputs", "display.2"), (bibleLibrary, "Bible Library", "books.vertical")] {
            let item = NSTabViewItem(viewController: controller); item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label); addTabViewItem(item)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class BibleLibrarySettingsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let table = NSTableView()
    let importButton = NSButton(title: "Import Bible…", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove…", target: nil, action: nil)
    let progress = NSProgressIndicator()
    let emptyLabel = nativeLabel("No translations imported")
    var onImport: () -> Void = {}
    var onRemove: (URL) -> Void = { _ in }
    private let library: BibleLibrary
    private var urls: [URL] = []
    private var subscriptions = Set<AnyCancellable>()

    init(library: BibleLibrary) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let explanation = NSTextField(wrappingLabelWithString: "Imported translations are available in every passage tab. Import the same file name again to replace a translation.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("translation")))
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 48
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Bible Library")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = table
        let list = NSView()
        pin(scroll, to: list)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: list.centerYAnchor)
        ])
        for button in [importButton, removeButton] { button.bezelStyle = .rounded; button.target = self }
        importButton.action = #selector(importBible(_:))
        removeButton.action = #selector(removeBible(_:))
        removeButton.toolTip = "Move the selected imported translation to Trash"
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("Importing Bible")
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        let buttons = horizontalStack([importButton, progress, NSView(), removeButton])
        let stack = NSStackView(views: [explanation, list, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        pin(stack, to: view, inset: 24)
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        explanation.setContentHuggingPriority(.required, for: .vertical)
        buttons.setContentHuggingPriority(.required, for: .vertical)
        library.$urls.receive(on: DispatchQueue.main)
            .sink { [weak self] urls in self?.apply(urls) }.store(in: &subscriptions)
        library.$isImporting.sink { [weak self] importing in self?.renderImportState(importing) }.store(in: &subscriptions)
    }
    private var selectedURL: URL? { urls.indices.contains(table.selectedRow) ? urls[table.selectedRow] : nil }
    private func apply(_ urls: [URL]) {
        let selected = selectedURL
        self.urls = urls
        table.reloadData()
        if let selected, let index = urls.firstIndex(of: selected) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        emptyLabel.isHidden = !urls.isEmpty
        updateRemoveButton()
    }
    private func renderImportState(_ importing: Bool) {
        importButton.isEnabled = !importing
        if importing { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        updateRemoveButton(isImporting: importing)
    }
    private func updateRemoveButton(isImporting: Bool? = nil) {
        removeButton.isEnabled = !(isImporting ?? library.isImporting) && selectedURL.map(library.isImported) == true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = urls[row]
        let title = nativeLabel(BibleTranslation.name(for: url))
        let detail = nativeLabel(library.isImported(url) ? "Imported · " + url.lastPathComponent : "Included with the app", size: 11)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        let cell = NSTableCellView()
        cell.textField = title
        cell.toolTip = url.lastPathComponent
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateRemoveButton() }
    @objc private func importBible(_ sender: Any?) { onImport() }
    @objc private func removeBible(_ sender: Any?) { if let url = selectedURL { onRemove(url) } }
}
