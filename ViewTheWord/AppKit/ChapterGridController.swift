import AppKit

/// Native chapter buttons flow into as many columns as the pane can fit.
@MainActor
final class ChapterGridController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
    let collection = ChapterCollectionView()
    let scrollView = NSScrollView()
    private(set) var references: [VerseReference] = []
    private(set) var selectedReference: VerseReference?
    private var applying = false
    private var revealTask: Task<Void, Never>?
    var onActivate: (VerseReference) -> Void = { _ in }
    var onOpenInNewTab: (VerseReference) -> Void = { _ in }
    var onMoveFocus: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}
    deinit { revealTask?.cancel() }

    var columnCount: Int {
        max(1, Int((scrollView.contentSize.width - 20 + 6) / (44 + 6)))
    }

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        collection.collectionViewLayout = layout
        collection.owner = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.register(ChapterItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("chapter"))
        collection.setAccessibilityLabel("Chapters")
        collection.setAccessibilityIdentifier("workspace-chapters")
        scrollView.documentView = collection
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        view = scrollView
    }

    func apply(book: String?, selection: VerseReference?) {
        _ = view
        let next = book.flatMap { book in VerseBoundary.chapterRange(for: book).map { range in
            range.compactMap { VerseReference(book: book, chapter: $0, verse: 1) }
        } } ?? []
        applying = true
        defer { applying = false }
        let changed = references != next
        let previous = selectedReference
        references = next
        selectedReference = selection
        if changed { collection.reloadData() }
        let index = selection.flatMap { references.firstIndex(of: $0) }
        let paths: Set<IndexPath> = index.map { [IndexPath(item: $0, section: 0)] } ?? []
        collection.selectionIndexPaths = paths
        if index != nil, changed || previous != selection {
            revealSelectionAfterLayout()
        }
    }
    func revealSelectionAfterLayout() {
        guard let selection = selectedReference, let index = references.firstIndex(of: selection) else { return }
        revealTask?.cancel()
        revealTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.selectedReference == selection else { return }
            self.collection.layoutSubtreeIfNeeded()
            self.collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
        }
    }
    func activate(_ index: Int) {
        guard references.indices.contains(index), !applying else { return }
        selectedReference = references[index]
        collection.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        collection.window?.makeFirstResponder(collection)
        onActivate(references[index])
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { references.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("chapter"), for: indexPath) as! ChapterItem
        let reference = references[indexPath.item]
        item.button.title = String(reference.chapter)
        item.button.setAccessibilityLabel("\(reference.book), chapter \(reference.chapter)")
        item.button.setAccessibilityIdentifier("chapter-\(reference.coordinate.book)-\(reference.chapter)")
        item.activate = { [weak self] in
            guard let self, let index = self.references.firstIndex(of: reference) else { return }
            self.activate(index)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.command("Open in New Tab") { [weak self] in self?.onOpenInNewTab(reference) }
        item.button.menu = menu
        item.button.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Open in New Tab") { [weak self] in
                self?.onOpenInNewTab(reference)
                return self != nil
            }
        ])
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if !applying, let path = indexPaths.first { activate(path.item) }
    }
    func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        let columns = CGFloat(columnCount)
        let available = scrollView.contentSize.width - 20 - (columns - 1) * 6
        return NSSize(width: max(32, floor(available / columns)), height: 30)
    }
}

@MainActor
final class ChapterCollectionView: NSCollectionView {
    weak var owner: ChapterGridController?
    override func setFrameSize(_ newSize: NSSize) {
        let resized = abs(frame.width - newSize.width) > 0.5
        let selectedWasVisible = !selectionIndexPaths.isDisjoint(with: indexPathsForVisibleItems())
        super.setFrameSize(newSize)
        if resized {
            collectionViewLayout?.invalidateLayout()
            if selectedWasVisible { owner?.revealSelectionAfterLayout() }
        }
    }
    override func cancelOperation(_ sender: Any?) { owner?.onCancel() }
    override func insertNewline(_ sender: Any?) {
        if let item = selectionIndexPaths.first?.item { owner?.activate(item) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { insertNewline(nil); return }
        if event.keyCode == 53 { cancelOperation(nil); return }
        // Tab uses AppKit's key-view loop. Command-arrow moves between columns;
        // ordinary arrows keep NSCollectionView's spatial grid navigation.
        if event.modifierFlags.contains(.command), event.keyCode == 123 || event.keyCode == 124 {
            owner?.onMoveFocus(event.keyCode == 123 ? -1 : 1)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class ChapterItem: NSCollectionViewItem {
    let button = NSButton(title: "", target: nil, action: nil)
    var activate: () -> Void = {}
    override func loadView() {
        button.bezelStyle = .rounded
        button.setButtonType(.pushOnPushOff)
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.target = self
        button.action = #selector(choose)
        view = button
    }
    override var isSelected: Bool {
        didSet { button.state = isSelected ? .on : .off }
    }
    @objc private func choose() { activate() }
}
