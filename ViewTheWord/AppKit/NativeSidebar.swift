import AppKit

/// Stable identities are shared by selection, accessibility, and menu actions.
final class SidebarNode: NSObject {
    let id: String
    let title: String
    let reference: VerseReference?
    let book: String?
    let children: [SidebarNode]?
    let systemImage: String?

    init(id: String, title: String, reference: VerseReference? = nil, book: String? = nil,
         children: [SidebarNode]? = nil, systemImage: String? = nil) {
        self.id = id
        self.title = title
        self.reference = reference
        self.book = book
        self.children = children
        self.systemImage = systemImage
    }

    var signature: String { id + title + (children?.map(\.signature).joined(separator: "\n") ?? "") }
}

@MainActor
final class NativeSidebarController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = SidebarOutlineView()
    let scrollView = NSScrollView()
    private(set) var nodes: [SidebarNode] = []
    private var applying = false
    private let label: String
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    var onActivate: (SidebarNode) -> Void = { _ in }
    var onMoveFocus: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}
    var onContextMenu: (SidebarNode) -> NSMenu? = { _ in nil }

    init(label: String) {
        self.label = label
        super.init(nibName: nil, bundle: nil)
        outline.owner = self
        outline.setAccessibilityLabel(label)
        outline.setAccessibilityIdentifier("workspace-" + (label == "Bible books" ? "books" : label.lowercased()))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        outline.headerView = nil
        outline.delegate = self
        outline.dataSource = self
        outline.style = label == "Bible books" ? .sourceList : .plain
        outline.backgroundColor = .controlBackgroundColor
        outline.rowSizeStyle = .medium
        outline.rowHeight = 28
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.autoresizingMask = [.width]
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        view = NSView()
        pin(scrollView, to: view)
        emptyLabel.stringValue = label == "Bookmarks" ? "Bookmark verses to find them here." : "Submitted references appear here."
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            emptyLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12)
        ])
    }

    func apply(_ nodes: [SidebarNode], selectionID: String? = nil, preserveSelection: Bool = false) {
        _ = view
        let oldSelection = selectedNode?.id
        let changed = self.nodes.map(\.signature) != nodes.map(\.signature)
        applying = true
        defer { applying = false }
        if changed {
            let oldGroups = allNodes(self.nodes).filter { $0.children != nil }
            let collapsed = Set(oldGroups.filter { !outline.isItemExpanded($0) }.map(\.id))
            self.nodes = nodes
            outline.reloadData()
            for node in allNodes(nodes) where node.children != nil && !collapsed.contains(node.id) {
                outline.expandItem(node)
            }
        }
        emptyLabel.isHidden = label == "Bible books" || !allNodes(self.nodes).filter { $0.children == nil }.isEmpty
        let targetID = preserveSelection ? (selectionID ?? oldSelection) : selectionID
        let target = allNodes(self.nodes).first { $0.id == targetID }
        let row = target.map { outline.row(forItem: $0) } ?? -1
        if outline.selectedRow != row {
            outline.selectRowIndexes(row >= 0 ? IndexSet(integer: row) : [], byExtendingSelection: false)
            if row >= 0 && !preserveSelection { outline.scrollRowToVisible(row) }
        }
    }

    var selectedNode: SidebarNode? { outline.item(atRow: outline.selectedRow) as? SidebarNode }
    private func allNodes(_ nodes: [SidebarNode]) -> [SidebarNode] {
        nodes.flatMap { [$0] + allNodes($0.children ?? []) }
    }
    func activateSelected() {
        guard let node = selectedNode, node.children == nil else { return }
        onActivate(node)
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !applying { activateSelected() }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children?.count ?? (item == nil ? nodes.count : 0)
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? SidebarNode)?.children ?? nodes)[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.children != nil
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.children == nil
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.children != nil
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? SidebarNode)?.children == nil ? 30 : 26
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier(node.children == nil ? "sidebar-item" : "sidebar-group")
        let cell = outline.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: node.systemImage == nil ? 4 : 25),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            if let symbol = node.systemImage {
                let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
                icon.contentTintColor = .secondaryLabelColor
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                cell.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 14),
                    icon.heightAnchor.constraint(equalToConstant: 14)
                ])
            }
        }
        cell.textField?.stringValue = node.title
        cell.textField?.font = .systemFont(ofSize: node.children == nil ? 13 : 11,
                                           weight: node.children == nil ? .regular : .semibold)
        cell.textField?.textColor = node.children == nil ? .labelColor : .secondaryLabelColor
        cell.setAccessibilityLabel(node.title)
        cell.setAccessibilityIdentifier(node.id)
        return cell
    }
    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? SidebarNode)?.title
    }
}

@MainActor
final class SidebarOutlineView: NSOutlineView {
    weak var owner: NativeSidebarController?
    override func mouseDown(with event: NSEvent) {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        let previous = selectedRow
        super.mouseDown(with: event)
        if clicked >= 0 && clicked == previous && selectedRow == previous { owner?.activateSelected() }
    }
    override func insertNewline(_ sender: Any?) { owner?.activateSelected() }
    override func cancelOperation(_ sender: Any?) { owner?.onCancel() }
    override func moveRight(_ sender: Any?) {
        if owner?.selectedNode?.children != nil { super.moveRight(sender) }
        else { owner?.onMoveFocus(1) }
    }
    override func moveLeft(_ sender: Any?) {
        if owner?.selectedNode?.children != nil { super.moveLeft(sender) }
        else { owner?.onMoveFocus(-1) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let node = item(atRow: row(at: convert(event.locationInWindow, from: nil))) as? SidebarNode else { return nil }
        return owner?.onContextMenu(node)
    }
}
