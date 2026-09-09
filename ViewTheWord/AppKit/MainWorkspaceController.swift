import AppKit
import Combine

/// Owns the complete working interface. Model snapshots never request focus.
/// This is also the sole publisher and lifecycle owner of live projection.
@MainActor
final class MainWorkspaceController: NSViewController {
    let navigation: VerseTargetModel
    let projector: ProjectorViewModel
    let history: HistoryStore
    let bookmarks: BookmarkStore
    let library: BibleLibrary
    let defaults: UserDefaults
    let sourceResolver: ((Bool) -> BibleSources)?
    var projectorWindowFactory: ((ProjectorViewModel) -> NSWindow?)?

    let books = NativeSidebarController(label: "Bible books")
    let savedBookmarks = NativeSidebarController(label: "Bookmarks")
    let savedHistory = NativeSidebarController(label: "History")
    let chapters = ChapterGridController()
    let verses = NativeReferenceTableController()
    let split = NSSplitViewController()
    let chapterSplit = NSSplitViewController()
    let search = NativeSearchFieldController()
    let searchModeControl = NSSegmentedControl(labels: ["Ref", "Words", "Phrase"], trackingMode: .selectOne, target: nil, action: nil)
    let primaryPicker = NSPopUpButton()
    let secondaryPicker = NSPopUpButton()
    let chapterTitle = nativeLabel("Choose a book", size: 12, weight: .semibold)
    let referenceTitle = nativeLabel("View The Word", size: 14, weight: .semibold)
    let statusLabel = nativeLabel("Projection stopped", size: 12, weight: .medium)
    let screenLabel = nativeLabel("", size: 11)
    let loadingLabel = nativeLabel("", size: 11)
    let resultLabel = nativeLabel("", size: 12)
    let messageLabel = nativeLabel("", size: 12)
    let emptyLabel = NSTextField(wrappingLabelWithString: "Choose a book and chapter, or enter a reference in Search.")
    let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    let blankButton = NSButton(title: "Blank", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let loadMoreButton = NSButton(title: "Load more results", target: nil, action: nil)
    let savedActions = NSPopUpButton(frame: .zero, pullsDown: true)
    let historyActions = NSPopUpButton(frame: .zero, pullsDown: true)
    let viewOptions = NSPopUpButton(frame: .zero, pullsDown: true)
    let projectionOptions = NSPopUpButton(frame: .zero, pullsDown: true)
    let resultsHeader = NSStackView()
    let footer = NSStackView()
    let preview = NSPopover()
    var searchToolbarItem: NSSearchToolbarItem?

    private(set) var browsedBook: String?
    private(set) var searchMode = SearchMode.verseReference
    private(set) var draft = ""
    private var searchSelection: VerseReference?
    private var subscriptions = Set<AnyCancellable>()
    private var renderTask: Task<Void, Never>?
    var repositionTask: Task<Void, Never>?
    var ownedProjectorWindow: NSWindow?
    var windowOpened = false
    private var previousSources: BibleSources?
    private var previousDisplayID = 0
    private var previousTransparency = false
    private var presentingLibraryAlert = false
    private var shuttingDown = false

    init(navigation: VerseTargetModel? = nil, projector: ProjectorViewModel? = nil,
         history: HistoryStore? = nil, bookmarks: BookmarkStore? = nil,
         library: BibleLibrary? = nil, defaults: UserDefaults = .standard,
         sourceResolver: ((Bool) -> BibleSources)? = nil) {
        self.navigation = navigation ?? VerseTargetModel()
        self.projector = projector ?? ProjectorViewModel()
        self.history = history ?? .shared
        self.bookmarks = bookmarks ?? .shared
        self.library = library ?? .shared
        self.defaults = defaults
        self.sourceResolver = sourceResolver
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { renderTask?.cancel(); repositionTask?.cancel() }

    var primaryOnly: Bool { defaults.bool(forKey: AppDefaultsKey.showOnlyPrimary) }
    var sources: BibleSources {
        sourceResolver?(primaryOnly) ?? library.sources(
            primary: defaults.string(forKey: AppDefaultsKey.primaryBibleName) ?? bundledPrimaryBibleUrl?.absoluteString ?? "",
            secondary: defaults.string(forKey: AppDefaultsKey.secondaryBibleName) ?? bundledSecondaryBibleUrl?.absoluteString ?? "",
            primaryOnly: primaryOnly
        )
    }
    var rowFontSize: CGFloat {
        let value = defaults.double(forKey: AppDefaultsKey.verseRowFontSize)
        return value > 0 ? value : 17
    }
    var preferredDisplayID: Int { defaults.integer(forKey: AppDefaultsKey.projectorScreenDisplayID) }

    override func loadView() {
        view = NSView()
        view.setAccessibilityIdentifier("native-workspace")
        buildInterface()
        connectActions()
        previousSources = sources
        previousDisplayID = preferredDisplayID
        previousTransparency = defaults.bool(forKey: AppDefaultsKey.transparentBackground)
        for publisher in [navigation.objectWillChange, projector.objectWillChange, history.objectWillChange,
                          bookmarks.objectWillChange, library.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.scheduleProjectorReposition()
                self?.scheduleRender()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.ownedProjectorWindow else { return }
                self.handleProjectorWindowClosed()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .closeProjectorRequested)
            .sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow, window === self.ownedProjectorWindow else { return }
                self.closeProjector()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .focusSearchField)
            .sink { [weak self] _ in self?.focusSearch(nil) }.store(in: &subscriptions)
        render()
    }

    private func connectActions() {
        books.onActivate = { [weak self] node in if let book = node.book { self?.browse(book) } }
        books.onMoveFocus = { [weak self] direction in self?.moveFocus(from: .books, direction: direction) }
        books.onCancel = { [weak self] in self?.closeProjector() }
        chapters.onActivate = { [weak self] reference in self?.navigate(to: reference, focusVerses: false) }
        chapters.onMoveFocus = { [weak self] direction in self?.moveFocus(from: .chapters, direction: direction) }
        chapters.onCancel = { [weak self] in self?.closeProjector() }
        verses.onActivate = { [weak self] reference in self?.activateVerse(reference) }
        verses.onSelection = { [weak self] reference in
            guard let self, self.navigation.searchPage != nil else { return }
            self.searchSelection = reference
            self.scheduleRender()
        }
        verses.onToggle = { [weak self] reference in
            guard let self else { return }
            if self.windowOpened && self.projector.projectionOwner?.reference == reference { self.closeProjector() }
            else { self.activateVerse(reference) }
        }
        verses.onChapterStep = { [weak self] offset in
            guard let self else { return }
            let current = self.navigation.navigation.reference
            if let next = VerseReference(book: current.book, chapter: current.chapter + offset, verse: 1) { self.navigate(to: next) }
        }
        verses.onMoveFocus = { [weak self] direction in self?.moveFocus(from: .verses, direction: direction) }
        verses.onCancel = { [weak self] in self?.closeProjector() }
        verses.onBookmark = { [weak self] in self?.toggleBookmark($0) }
        for saved in [savedBookmarks, savedHistory] {
            saved.onActivate = { [weak self] node in
                if let reference = node.reference { self?.navigate(to: reference, project: true) }
            }
            saved.onMoveFocus = { [weak self] direction in self?.moveFocus(from: .chapters, direction: direction) }
            saved.onCancel = { [weak self] in self?.closeProjector() }
            saved.onContextMenu = { [weak self] node in self?.savedMenu(for: node) }
        }
        search.onTextChange = { [weak self] in self?.draft = $0 }
        search.onSubmit = { [weak self] in self?.submitSearch() }
        search.onClear = { [weak self] in
            self?.navigation.cancelLoading(clearSearch: true)
            self?.navigation.message = nil
            self?.searchSelection = nil
        }
        search.onCancel = { [weak self] in self?.closeProjector() }
        search.onMoveFocus = { [weak self] direction in self?.focus(direction < 0 ? .chapters : .verses) }
    }

    /// Coalesce model publications after their stored values have committed.
    /// AppKit owns focus throughout; refreshing controls never moves first responder.
    func scheduleRender() {
        guard renderTask == nil, !shuttingDown else { return }
        renderTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.renderTask = nil
            self.render()
        }
    }

    func render() {
        guard isViewLoaded, !shuttingDown else { return }
        let sources = sources
        if let previousSources, previousSources != sources {
            self.previousSources = sources
            refreshSources()
        }
        if previousDisplayID != preferredDisplayID {
            previousDisplayID = preferredDisplayID
            scheduleProjectorReposition()
        }
        let transparent = defaults.bool(forKey: AppDefaultsKey.transparentBackground)
        if transparent != previousTransparency {
            previousTransparency = transparent
            if let ownedProjectorWindow { applyProjectorAppearance(ownedProjectorWindow) }
        }
        books.apply([
            SidebarNode(id: "old-testament", title: "Old Testament", children: bibleBookNames.prefix(39).map {
                SidebarNode(id: "book-\($0)", title: $0, book: $0)
            }),
            SidebarNode(id: "new-testament", title: "New Testament", children: bibleBookNames.suffix(27).map {
                SidebarNode(id: "book-\($0)", title: $0, book: $0)
            })
        ], selectionID: browsedBook.map { "book-\($0)" })
        let current = navigation.refreshReference
        let selectedChapter = current.flatMap { reference in
            reference.book == browsedBook ? VerseReference(book: reference.book, chapter: reference.chapter, verse: 1) : nil
        }
        chapters.apply(book: browsedBook, selection: selectedChapter)
        chapterTitle.stringValue = browsedBook ?? "Chapters"
        renderSaved()
        renderSearchField()
        renderTranslationPickers(sources)
        if let page = navigation.searchPage, page.sources == sources {
            let rows = page.hits.map { hit in
                var row = makeVerseRow(hit.pair, sources: sources)
                let matches = [(hit.matchedPrimary, Optional(sources.primary)), (hit.matchedSecondary, sources.secondary)]
                    .compactMap { matched, url in matched ? url.map(BibleTranslation.name) : nil }.joined(separator: ", ")
                row.heading = hit.pair.reference.verseQuery.title + "  ·  " + matches
                return row
            }
            if !rows.contains(where: { $0.reference == searchSelection }) { searchSelection = rows.first?.reference }
            verses.activatesOnSelection = false
            verses.apply(rows: rows, selection: searchSelection, style: .results(fontSize: rowFontSize, dual: sources.secondary != nil), enabled: !navigation.isLoading)
            referenceTitle.stringValue = "Search results"
            resultLabel.stringValue = "\(page.hits.count)\(page.hasMore ? "+" : "") results for “\(page.request.text)”"
            resultsHeader.isHidden = false
            loadMoreButton.isHidden = !page.hasMore
            loadMoreButton.isEnabled = !navigation.isLoading
            emptyLabel.stringValue = "No matches. Try another phrase or change the search mode."
        } else {
            let chapter = navigation.navigation.chapter
            let rows = chapter?.sources == sources ? chapter?.rows ?? [] : []
            verses.activatesOnSelection = true
            verses.apply(rows: rows.map { makeVerseRow($0, sources: sources) }, selection: navigation.navigation.reference,
                         style: .verses(fontSize: rowFontSize, dual: sources.secondary != nil), enabled: !navigation.isLoading,
                         scrollRequest: chapter?.data.id)
            referenceTitle.stringValue = chapter == nil ? "View The Word" : navigation.verseQuery.bookAndChapter
            resultsHeader.isHidden = true
            loadMoreButton.isHidden = true
            emptyLabel.stringValue = navigation.isLoading ? "Loading chapter…" : "Choose a book and chapter, or enter a reference in Search."
        }
        emptyLabel.isHidden = !verses.rows.isEmpty
        renderStatus()
        rebuildOptionMenus()
        let messages = [navigation.message, bookmarks.issue, history.issue].compactMap { $0 }
        messageLabel.stringValue = messages.joined(separator: "  ")
        messageLabel.toolTip = messageLabel.stringValue
        footer.isHidden = messages.isEmpty
        presentLibraryAlertIfNeeded()
    }

    private func makeVerseRow(_ pair: TranslationPair, sources: BibleSources) -> NativeReferenceRow {
        func copy(_ verse: AVerse?, url: URL?) -> String? {
            guard let verse, let url else { return nil }
            return "\(verse.reference.verseQuery.title) \(verse.verse) (\(BibleTranslation.name(for: url)))"
        }
        return NativeReferenceRow(reference: pair.reference, primaryText: pair.primary?.verse ?? "", secondaryText: pair.secondary?.verse,
                                  bookmarked: bookmarks.contains(pair.reference), primaryCopy: copy(pair.primary, url: sources.primary),
                                  secondaryCopy: copy(pair.secondary, url: sources.secondary))
    }

    private func renderSaved() {
        let bookmarkRows = bookmarks.entries.compactMap { entry in entry.reference.map {
            SidebarNode(id: "bookmark-\(entry.id)", title: entry.title, reference: $0, systemImage: "bookmark")
        } }
        let weeks = history.groupedSections.map { section in
            SidebarNode(id: "week-\(section.id.timeIntervalSince1970)", title: section.title, children: section.items.compactMap { entry in
                SearchQuery(ask: entry.title).verseQuery().flatMap(VerseReference.init).map {
                    SidebarNode(id: "history-\(entry.id)", title: entry.title, reference: $0, systemImage: "clock")
                }
            })
        }
        savedBookmarks.apply(bookmarkRows, preserveSelection: true)
        savedHistory.apply(weeks, preserveSelection: true)
    }

    func browse(_ book: String) {
        guard book != browsedBook else { return }
        navigation.cancelLoading(clearSearch: true)
        browsedBook = book
        searchSelection = nil
        render()
    }

    func navigate(to reference: VerseReference, project: Bool = false, recordHistory: Bool = false,
                  updateDraft: Bool = true, focusVerses: Bool = true) {
        let originalDraft = draft
        navigation.navigate(to: reference, sources: sources, project: project) { [weak self] result in
            guard let self else { return }
            self.browsedBook = result.reference.book
            if updateDraft && self.draft == originalDraft {
                self.draft = result.reference.verseQuery.title
                if focusVerses { self.focus(.verses) }
            }
            if recordHistory && result.requestedAvailable { self.history.append(reference.verseQuery.title) }
            if let projection = result.projection { self.publish(projection) }
            self.scheduleRender()
        }
        scheduleRender()
    }

    func submitSearch() {
        do {
            switch try SearchQuery(ask: draft).searchType(mode: searchMode) {
            case .verse(let query):
                guard let reference = VerseReference(query) else { throw QueryError.invalidReference }
                navigate(to: reference, project: true, recordHistory: true)
            case .text(let request):
                searchSelection = nil
                navigation.search(request, sources: sources) { [weak self] in self?.focus(.verses) }
            }
        } catch {
            navigation.cancelAll()
            navigation.message = error.localizedDescription
            NSSound.beep()
        }
    }

    func changeSearchMode(_ mode: SearchMode) {
        guard mode != searchMode else { return }
        searchMode = mode
        draft = ""
        searchSelection = nil
        navigation.cancelLoading(clearSearch: true)
        navigation.message = nil
        if navigation.navigation.chapter?.sources != sources, let reference = navigation.refreshReference {
            navigate(to: reference, updateDraft: false, focusVerses: false)
        }
        renderSearchField()
        scheduleRender()
        focusSearch(nil)
    }

    func activateVerse(_ reference: VerseReference) {
        if navigation.searchPage != nil {
            navigation.requestProjection(owner: .searchResult(reference), sources: sources) { [weak self] projection in
                if let projection { self?.publish(projection) }
            }
        } else {
            guard let projection = navigation.prepareRowProjection(reference, sources: sources) else { return }
            browsedBook = reference.book
            draft = reference.verseQuery.title
            publish(projection)
        }
    }

    func refreshSources() {
        let liveOwner = projector.projectionOwner
        navigation.cancelProjection()
        if let request = navigation.searchRequest { navigation.search(request, sources: sources) }
        else if let reference = navigation.refreshReference { navigate(to: reference, updateDraft: false) }
        else { navigation.cancelLoading() }
        if windowOpened, let liveOwner {
            navigation.requestProjection(owner: liveOwner, sources: sources) { [weak self] projection in
                if let projection { self?.publish(projection, preserveBlanking: true) }
                else { self?.closeProjector() }
            }
        }
    }

    func toggleBookmark(_ reference: VerseReference) {
        if bookmarks.contains(reference) { bookmarks.remove(reference, undoManager: view.window?.undoManager) }
        else { bookmarks.add(reference, undoManager: view.window?.undoManager) }
    }

    enum FocusColumn: CaseIterable { case books, chapters, search, verses }
    func focus(_ column: FocusColumn) {
        switch column {
        case .books: view.window?.makeFirstResponder(books.outline)
        case .chapters: view.window?.makeFirstResponder(chapters.collection)
        case .search: focusSearch(nil)
        case .verses: view.window?.makeFirstResponder(verses.table)
        }
    }
    func moveFocus(from column: FocusColumn, direction: Int) {
        let columns = FocusColumn.allCases
        let index = columns.firstIndex(of: column) ?? 0
        focus(columns[(index + direction + columns.count) % columns.count])
    }
    @objc func focusSearch(_ sender: Any?) {
        searchToolbarItem?.beginSearchInteraction()
        view.window?.makeFirstResponder(search.field)
    }
    override func cancelOperation(_ sender: Any?) { closeProjector() }
    func shutdown() {
        shuttingDown = true
        navigation.cancelAll()
        closeProjector()
        renderTask?.cancel()
        subscriptions.removeAll()
    }

    private func presentLibraryAlertIfNeeded() {
        guard !presentingLibraryAlert, library.presentationTarget == .main, let window = view.window else { return }
        if let url = library.pendingReplacement {
            presentingLibraryAlert = true
            let alert = NSAlert()
            alert.messageText = "Replace imported translation?"
            alert.informativeText = "Replace \(url.lastPathComponent) with the selected file?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                self.presentingLibraryAlert = false
                self.library.pendingReplacement = nil
                if response == .alertFirstButtonReturn { self.library.importFile(url, replaceExisting: true, presenter: .main) }
            }
        } else if let notice = library.notice {
            presentingLibraryAlert = true
            library.notice = nil
            let alert = NSAlert()
            alert.messageText = "Bible Library"
            alert.informativeText = notice
            alert.beginSheetModal(for: window) { [weak self] _ in self?.presentingLibraryAlert = false }
        }
    }
}
