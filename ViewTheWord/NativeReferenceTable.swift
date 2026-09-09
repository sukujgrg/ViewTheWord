import AppKit

struct NativeReferenceRow: Equatable {
    let reference: VerseReference
    let primaryText: String
    var secondaryText: String?
    var bookmarked = false
    var primaryCopy: String?
    var secondaryCopy: String?
    var heading: String?
}

enum NativeReferenceStyle: Equatable {
    case chapters
    case verses(fontSize: CGFloat, dual: Bool)
    case results(fontSize: CGFloat, dual: Bool)

    var isVerse: Bool {
        self != .chapters
    }
    var fontSize: CGFloat {
        if case .verses(let size, _) = self { return size }
        if case .results(let size, _) = self { return size }
        return 13
    }
    var dual: Bool {
        if case .verses(_, let dual) = self { return dual }
        if case .results(_, let dual) = self { return dual }
        return false
    }
    var isSearch: Bool { if case .results = self { return true }; return false }
}

@MainActor
final class NativeReferenceTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let table = ReferenceNSTableView()
    private(set) var rows: [NativeReferenceRow] = []
    private(set) var style: NativeReferenceStyle = .chapters
    private(set) var enabled = true
    private var isApplyingSnapshot = false
    private var resizeTask: Task<Void, Never>?
    private var lastScrollRequest: UUID?
    var onActivate: (VerseReference) -> Void = { _ in }
    var onToggle: (VerseReference) -> Void = { _ in }
    var onChapterStep: (Int) -> Void = { _ in }
    var onMoveFocus: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onBookmark: (VerseReference) -> Void = { _ in }
    var onOpenInNewTab: (VerseReference) -> Void = { _ in }
    var activatesOnSelection = true
    var onSelection: (VerseReference) -> Void = { _ in }

    override init() {
        super.init()
        table.controller = self
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.style = .plain
        table.backgroundColor = .textBackgroundColor
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.usesAutomaticRowHeights = true
        table.rowHeight = 30
        table.setAccessibilityLabel("Reference list")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reference"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
    }

    deinit { resizeTask?.cancel() }

    func apply(rows newRows: [NativeReferenceRow], selection: VerseReference?,
               style newStyle: NativeReferenceStyle, enabled: Bool = true, scrollRequest: UUID? = nil) {
        let referencesChanged = rows.map(\.reference) != newRows.map(\.reference)
        let layoutChanged = referencesChanged || style != newStyle
            || zip(rows, newRows).contains { $0.primaryText != $1.primaryText || $0.secondaryText != $1.secondaryText || $0.heading != $1.heading }
        let revealRequested = lastScrollRequest != scrollRequest
        lastScrollRequest = scrollRequest
        let oldSelection = selectedReference
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }
        rows = newRows
        style = newStyle
        self.enabled = enabled
        table.usesAlternatingRowBackgroundColors = style.isVerse
        table.setAccessibilityLabel(style.isSearch ? "Search results" : style.isVerse ? "Bible verses" : "Chapters")
        if layoutChanged {
            table.rowHeight = style.isVerse ? 100 : 30
            table.reloadData()
        }
        let index = selection.flatMap { reference in rows.firstIndex { $0.reference == reference } }
        if table.selectedRow != (index ?? -1) {
            table.selectRowIndexes(index.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
        }
        refreshVisibleCells()
        if let index, referencesChanged || revealRequested || oldSelection != selection {
            table.scrollRowToVisible(index)
        }
        if layoutChanged { resized() }
    }

    var selectedReference: VerseReference? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].reference : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func selectionShouldChange(in tableView: NSTableView) -> Bool { isApplyingSnapshot || enabled }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("reference-cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ReferenceTableCell
            ?? ReferenceTableCell()
        cell.identifier = identifier
        configure(cell, at: row)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard rows.indices.contains(row) else { return nil }
        let view = ReferenceTableRowView()
        let reference = rows[row].reference
        view.activate = { [weak self] in
            guard let self, self.enabled,
                  let index = self.rows.firstIndex(where: { $0.reference == reference }) else { return false }
            if self.table.selectedRow == index { self.activateSelected() }
            else {
                self.selectFromKeyboard(index)
                if !self.activatesOnSelection { self.activateSelected() }
            }
            return true
        }
        view.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: style.isVerse ? "Project verse" : "Open chapter") { [weak view] in
                view?.accessibilityPerformPress() ?? false
            },
            NSAccessibilityCustomAction(name: "Open in New Tab") { [weak self] in
                guard let self, self.enabled else { return false }
                self.onOpenInNewTab(reference)
                return true
            }
        ])
        return view
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard rows.indices.contains(row) else { return nil }
        return String(style.isVerse ? rows[row].reference.verse : rows[row].reference.chapter)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSnapshot, enabled, let reference = selectedReference else { return }
        onSelection(reference)
        if activatesOnSelection { onActivate(reference) }
    }

    func activateSelected() {
        guard enabled, let reference = selectedReference else { return }
        onActivate(reference)
    }

    func moveSelection(offset: Int) {
        guard enabled, !rows.isEmpty else { return }
        let current = table.selectedRow
        let next = current < 0 ? (offset >= 0 ? 0 : rows.count - 1)
            : min(rows.count - 1, max(0, current + offset))
        selectFromKeyboard(next)
    }

    func selectFromKeyboard(_ index: Int) {
        guard enabled, rows.indices.contains(index) else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    func resized() {
        // AppKit can resize the document view while asking its delegate for rows.
        // Recalculate after that layout pass, once the column width has settled.
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, !self.rows.isEmpty else { return }
            self.resizeTask = nil
            self.refreshVisibleCells()
            self.table.layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                self.table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: self.rows.indices))
            }, completionHandler: nil)
        }
    }

    func tableViewColumnDidResize(_ notification: Notification) { resized() }

    private func configure(_ cell: ReferenceTableCell, at index: Int) {
        let item = rows[index]
        cell.configure(item, style: style, selected: table.selectedRow == index, enabled: enabled,
                       width: table.tableColumns[0].width)
        cell.onBookmark = { [weak self] in self?.onBookmark(item.reference) }
        cell.makeCopyMenu = { [weak self] in self?.menu(for: item, includeBookmark: false) ?? NSMenu() }
    }

    private func refreshVisibleCells() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound, visible.length > 0 else { return }
        for index in visible.location..<min(rows.count, NSMaxRange(visible)) {
            if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? ReferenceTableCell {
                configure(cell, at: index)
            }
        }
    }

    func contextMenu(at index: Int) -> NSMenu? {
        guard enabled, rows.indices.contains(index), style.isVerse else { return nil }
        return menu(for: rows[index], includeBookmark: true)
    }

    private func menu(for item: NativeReferenceRow, includeBookmark: Bool) -> NSMenu {
        let menu = NSMenu()
        if let text = item.primaryCopy {
            menu.addAction(title: style.dual ? "Copy Verse (Primary)" : "Copy Verse") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        if style.dual, let text = item.secondaryCopy {
            menu.addAction(title: "Copy Verse (Secondary)") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        if includeBookmark {
            menu.addAction(title: "Open in New Tab") { [weak self] in self?.onOpenInNewTab(item.reference) }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addAction(title: item.bookmarked ? "Remove Bookmark" : "Add Bookmark") { [weak self] in
                self?.onBookmark(item.reference)
            }
        }
        return menu
    }
}

@MainActor
final class ReferenceNSTableView: NSTableView, NSMenuItemValidation {
    weak var controller: NativeReferenceTableController?
    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed { controller?.resized() }
    }
    override func mouseDown(with event: NSEvent) {
        guard controller?.enabled == true else { return }
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        let oldSelection = selectedRow
        super.mouseDown(with: event)
        // Selection delegates don't fire for an already-selected row.
        if clicked >= 0, selectedRow == clicked,
           controller?.activatesOnSelection == false || clicked == oldSelection {
            controller?.activateSelected()
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.contextMenu(at: row(at: convert(event.locationInWindow, from: nil)))
    }
    override func keyDown(with event: NSEvent) {
        guard let controller else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let characters = event.charactersIgnoringModifiers ?? ""
        // These are presentation-specific shortcuts. All standard movement and
        // cancel commands go through AppKit's configurable key bindings below.
        if controller.style.isVerse && !controller.style.isSearch, modifiers == .option || modifiers == .command,
           characters == "\u{F700}" || characters == "\u{F701}" {
            guard controller.enabled else { return }
            let direction = characters == "\u{F701}" ? 1 : -1
            if modifiers == .option {
                controller.onChapterStep(direction)
            } else {
                controller.moveSelection(offset: direction * 5)
            }
            return
        }
        if characters == " ", modifiers.isEmpty {
            guard controller.enabled, let reference = controller.selectedReference else { return }
            controller.onToggle(reference)
            return
        }
        // NSTableView handles Tab/Shift-Tab traversal itself. Interpreting these
        // as editing commands bypasses AppKit's key-view loop and traps focus.
        if event.keyCode == 48 { super.keyDown(with: event); return }
        let isCommand = !modifiers.intersection([.control, .command]).isEmpty
            || characters.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
            }
        if isCommand { interpretKeyEvents([event]) }
        else { super.keyDown(with: event) } // Keep native numeric type selection.
    }

    override func moveUp(_ sender: Any?) { controller?.moveSelection(offset: -1) }
    override func moveDown(_ sender: Any?) { controller?.moveSelection(offset: 1) }
    override func moveLeft(_ sender: Any?) { controller?.onMoveFocus(-1) }
    override func moveRight(_ sender: Any?) { controller?.onMoveFocus(1) }
    override func pageUp(_ sender: Any?) { controller?.moveSelection(offset: -10) }
    override func pageDown(_ sender: Any?) { controller?.moveSelection(offset: 10) }
    override func scrollPageUp(_ sender: Any?) { pageUp(sender) }
    override func scrollPageDown(_ sender: Any?) { pageDown(sender) }
    override func moveToBeginningOfDocument(_ sender: Any?) { controller?.selectFromKeyboard(0) }
    override func moveToEndOfDocument(_ sender: Any?) {
        if let controller { controller.selectFromKeyboard(controller.rows.count - 1) }
    }
    override func scrollToBeginningOfDocument(_ sender: Any?) { moveToBeginningOfDocument(sender) }
    override func scrollToEndOfDocument(_ sender: Any?) { moveToEndOfDocument(sender) }
    override func insertNewline(_ sender: Any?) { controller?.activateSelected() }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }
    override func cancelOperation(_ sender: Any?) { controller?.onCancel() }

    private var selectedCopyText: String? {
        guard let controller, controller.enabled, controller.style.isVerse,
              controller.rows.indices.contains(selectedRow) else { return nil }
        let item = controller.rows[selectedRow]
        return item.primaryCopy ?? (controller.style.dual ? item.secondaryCopy : nil)
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedCopyText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copy(_:)) ? selectedCopyText != nil : true
    }
}

@MainActor
private final class ReferenceTableRowView: NSTableRowView {
    var activate: () -> Bool = { false }
    override func accessibilityPerformPress() -> Bool { activate() }

}

@MainActor
private final class ReferenceTableCell: NSTableCellView {
    private let number = NSTextField(labelWithString: "")
    private let heading = NSTextField(labelWithString: "")
    private let primary = NSTextField(wrappingLabelWithString: "")
    private let secondary = NSTextField(wrappingLabelWithString: "")
    private let divider = NSBox()
    private let bookmark = NSButton()
    private let copyButton = NSButton()
    private var style: NativeReferenceStyle = .chapters
    private var selected = false
    private var hovered = false
    private var reference: VerseReference?
    private var tracking: NSTrackingArea?
    private var layoutConstraints: [NSLayoutConstraint] = []
    var onBookmark: () -> Void = {}
    var makeCopyMenu: () -> NSMenu = { NSMenu() }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [number, heading, primary, secondary, divider, bookmark, copyButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        number.alignment = .right
        for field in [primary, secondary] {
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.alignment = .natural
            field.isSelectable = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        divider.boxType = .separator
        bookmark.isBordered = false
        bookmark.target = self
        bookmark.action = #selector(toggleBookmark)
        copyButton.isBordered = false
        copyButton.target = self
        copyButton.action = #selector(showCopyMenu)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy verse")
        copyButton.setAccessibilityLabel("Copy verse")
        copyButton.toolTip = "Copy verse"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: NativeReferenceRow, style: NativeReferenceStyle, selected: Bool, enabled: Bool, width: CGFloat) {
        if reference != row.reference { hovered = false }
        reference = row.reference
        let layoutChanged = layoutConstraints.isEmpty || self.style.isVerse != style.isVerse || self.style.dual != style.dual || self.style.isSearch != style.isSearch
        self.style = style
        self.selected = selected
        primary.stringValue = row.primaryText
        secondary.stringValue = row.secondaryText ?? ""
        primary.font = .systemFont(ofSize: style.fontSize, weight: !style.isVerse && selected ? .semibold : .regular)
        secondary.font = .systemFont(ofSize: style.fontSize)
        primary.textColor = .labelColor
        secondary.textColor = .labelColor
        heading.stringValue = row.heading ?? row.reference.verseQuery.title
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail
        heading.isHidden = !style.isSearch
        number.stringValue = String(row.reference.verse)
        number.font = .monospacedDigitSystemFont(ofSize: max(11, style.fontSize * 0.72), weight: .semibold)
        number.textColor = selected ? .labelColor : .secondaryLabelColor
        number.isHidden = !style.isVerse || style.isSearch
        secondary.isHidden = !style.dual
        divider.isHidden = !style.dual
        if layoutChanged { configureConstraints() }
        updateWrappingWidth(width)
        let bookmarkTitle = row.bookmarked ? "Remove bookmark" : "Add bookmark"
        bookmark.image = NSImage(systemSymbolName: row.bookmarked ? "bookmark.fill" : "bookmark", accessibilityDescription: bookmarkTitle)
        bookmark.contentTintColor = row.bookmarked && !selected ? .controlAccentColor : .secondaryLabelColor
        bookmark.setAccessibilityLabel("\(bookmarkTitle), \(row.reference.verseQuery.title)")
        bookmark.toolTip = bookmarkTitle
        bookmark.isEnabled = enabled
        copyButton.isEnabled = enabled && (row.primaryCopy != nil || row.secondaryCopy != nil)
        setAccessibilityLabel(style.isVerse ? row.reference.verseQuery.title : row.primaryText)
        setAccessibilityIdentifier("reference-\(row.reference.coordinate.book)-\(row.reference.chapter)-\(row.reference.verse)")
        updateActions()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateWrappingWidth(newSize.width)
    }

    private func updateWrappingWidth(_ width: CGFloat) {
        // Give the native fields the same outer width as their constraints.
        // Their intrinsic heights include NSTextField's own text insets and wrapping.
        let available = max(1, width - (style.isVerse && !style.isSearch ? 70 : 30))
        let textWidth = style.dual ? max(1, (available - 25) / 2) : available
        for field in [primary, secondary] where field.preferredMaxLayoutWidth != textWidth {
            field.preferredMaxLayoutWidth = textWidth
        }
    }

    private func configureConstraints() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        if !style.isVerse {
            layoutConstraints = [
                primary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
                primary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
                primary.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                primary.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 30)
            ]
        } else {
            layoutConstraints = [
                heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
                number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                number.widthAnchor.constraint(equalToConstant: 32),
                number.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                primary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: style.isSearch ? 15 : 56),
                primary.topAnchor.constraint(equalTo: topAnchor, constant: style.isSearch ? 32 : 10),
                bottomAnchor.constraint(equalTo: primary.bottomAnchor, constant: 34),
                bookmark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -40),
                bookmark.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                bookmark.widthAnchor.constraint(equalToConstant: 24),
                bookmark.heightAnchor.constraint(equalToConstant: 23),
                copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
                copyButton.bottomAnchor.constraint(equalTo: bookmark.bottomAnchor),
                copyButton.widthAnchor.constraint(equalToConstant: 24),
                copyButton.heightAnchor.constraint(equalToConstant: 23)
            ]
            if style.isSearch {
                layoutConstraints += [
                    heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
                    heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
                    heading.topAnchor.constraint(equalTo: topAnchor, constant: 8)
                ]
            }
            if style.dual {
                layoutConstraints += [
                    secondary.leadingAnchor.constraint(equalTo: primary.trailingAnchor, constant: 25),
                    secondary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                    secondary.widthAnchor.constraint(equalTo: primary.widthAnchor),
                    secondary.topAnchor.constraint(equalTo: primary.topAnchor),
                    bottomAnchor.constraint(equalTo: secondary.bottomAnchor, constant: 34),
                    divider.leadingAnchor.constraint(equalTo: primary.trailingAnchor, constant: 12),
                    divider.widthAnchor.constraint(equalToConstant: 1),
                    divider.topAnchor.constraint(equalTo: primary.topAnchor),
                    divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -34)
                ]
            } else {
                layoutConstraints.append(primary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14))
            }
        }
        NSLayoutConstraint.activate(layoutConstraints)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateActions() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateActions() }
    private func updateActions() {
        bookmark.isHidden = !style.isVerse || (!selected && !hovered)
        copyButton.isHidden = bookmark.isHidden
    }
    @objc private func toggleBookmark() { onBookmark() }
    @objc private func showCopyMenu() {
        makeCopyMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: copyButton.bounds.maxY), in: copyButton)
    }
}

@MainActor
private final class ReferenceMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}

@MainActor
private extension NSMenu {
    func addAction(title: String, action: @escaping () -> Void) {
        let target = ReferenceMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(ReferenceMenuAction.invoke(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        addItem(item)
    }
}
