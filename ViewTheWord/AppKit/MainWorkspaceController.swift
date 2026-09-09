import AppKit
import Combine

/// One passage workspace. Model snapshots never request focus.
/// Live output belongs to the shared LiveProjectionController.
@MainActor
final class MainWorkspaceController: NSViewController {
    let navigation: VerseTargetModel
    let liveProjection: LiveProjectionController
    var projector: ProjectorViewModel { liveProjection.projector }
    var windowOpened: Bool { liveProjection.windowOpened }
    var onOpenInNewTab: ((VerseReference?) -> Void)?
    let history: HistoryStore
    let bookmarks: BookmarkStore
    let library: BibleLibrary
    let defaults: UserDefaults

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
    private var previousSources: BibleSources?
    private var presentingLibraryAlert = false
    private var shuttingDown = false

    init(navigation: VerseTargetModel? = nil, projector: ProjectorViewModel? = nil,
         history: HistoryStore? = nil, bookmarks: BookmarkStore? = nil,
         library: BibleLibrary? = nil, defaults: UserDefaults = .standard,
         sourceResolver: ((Bool) -> BibleSources)? = nil, liveProjection: LiveProjectionController? = nil) {
        self.navigation = navigation ?? VerseTargetModel()
        let liveProjection = liveProjection ?? LiveProjectionController(projector: projector, library: library, defaults: defaults, sourceResolver: sourceResolver)
        self.liveProjection = liveProjection
        self.history = history ?? .shared
        self.bookmarks = bookmarks ?? .shared
        self.library = liveProjection.library
        self.defaults = liveProjection.defaults
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { renderTask?.cancel() }

    var primaryOnly: Bool { defaults.bool(forKey: AppDefaultsKey.showOnlyPrimary) }
    var sources: BibleSources { liveProjection.sources }
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
        for publisher in [navigation.objectWillChange, liveProjection.objectWillChange, projector.objectWillChange, history.objectWillChange,
                          bookmarks.objectWillChange, library.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .focusSearchField)
            .sink { [weak self] _ in
                guard let self, self.view.window?.isKeyWindow == true else { return }
                self.focusSearch(nil)
            }.store(in: &subscriptions)
        render()
    }

    private func connectActions() {
        books.onActivate = { [weak self] node in if let book = node.book { self?.browse(book) } }
        books.onMoveFocus = { [weak self] direction in self?.moveFocus(from: .books, direction: direction) }
        books.onContextMenu = { [weak self] node in
            guard let self, let book = node.book, let reference = VerseReference(book: book, chapter: 1, verse: 1) else { return nil }
            return self.passageMenu(for: reference)
        }
        books.onCancel = { [weak self] in self?.closeProjector() }
        chapters.onActivate = { [weak self] reference in self?.navigate(to: reference, focusVerses: false) }
        chapters.onMoveFocus = { [weak self] direction in self?.moveFocus(from: .chapters, direction: direction) }
        chapters.onOpenInNewTab = { [weak self] in self?.onOpenInNewTab?($0) }
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
        verses.onOpenInNewTab = { [weak self] in self?.onOpenInNewTab?($0) }
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
        liveProjection.refreshPreferences()
        let sources = sources
        if let previousSources, previousSources != sources {
            self.previousSources = sources
            refreshSources()
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
        let title = navigation.searchPage != nil ? "Search" : navigation.refreshReference?.verseQuery.bookAndChapter ?? browsedBook ?? "New Passage"
        view.window?.title = title
        view.window?.tab.title = title
        view.window?.tab.toolTip = navigation.searchPage.map { "Search: " + $0.request.text } ?? title
        emptyLabel.isHidden = !verses.rows.isEmpty
        renderStatus()
        rebuildOptionMenus()
        let messages = [navigation.message, liveProjection.message, bookmarks.issue, history.issue].compactMap { $0 }
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
        let intent = project ? liveProjection.beginIntent(using: navigation) : nil
        navigation.navigate(to: reference, sources: sources, project: project) { [weak self] result in
            guard let self else { return }
            self.browsedBook = result.reference.book
            if updateDraft && self.draft == originalDraft {
                self.draft = result.reference.verseQuery.title
                if focusVerses { self.focus(.verses) }
            }
            if recordHistory && result.requestedAvailable { self.history.append(reference.verseQuery.title) }
            if let projection = result.projection, let intent { self.liveProjection.publish(projection, intent: intent) }
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
            liveProjection.requestProjection(owner: .searchResult(reference), using: navigation)
        } else {
            guard let projection = navigation.prepareRowProjection(reference, sources: sources) else { return }
            browsedBook = reference.book
            draft = reference.verseQuery.title
            liveProjection.publishRow(projection)
        }
    }

    func refreshSources() {
        if let request = navigation.searchRequest { navigation.search(request, sources: sources) }
        else if let reference = navigation.refreshReference { navigate(to: reference, updateDraft: false, focusVerses: false) }
        else { navigation.cancelLoading() }
    }

    func toggleBookmark(_ reference: VerseReference) {
        if bookmarks.contains(reference) { bookmarks.remove(reference, undoManager: view.window?.undoManager) }
        else { bookmarks.add(reference, undoManager: view.window?.undoManager) }
    }

    enum FocusColumn: CaseIterable { case books, chapters, search, verses }
    func focus(_ column: FocusColumn) {
        guard view.window?.isKeyWindow == true else { return }
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
        guard view.window?.isKeyWindow == true else { return }
        searchToolbarItem?.beginSearchInteraction()
        view.window?.makeFirstResponder(search.field)
    }
    override func cancelOperation(_ sender: Any?) { closeProjector() }
    func shutdown() {
        shuttingDown = true
        navigation.cancelAll()
        preview.performClose(nil)
        renderTask?.cancel()
        subscriptions.removeAll()
    }

    private func presentLibraryAlertIfNeeded() {
        guard !presentingLibraryAlert, library.presentationTarget == .main, let window = view.window, window.isKeyWindow else { return }
        if let url = library.pendingReplacement {
            // Claim the shared request before another passage window can present it.
            library.pendingReplacement = nil
            presentingLibraryAlert = true
            let alert = NSAlert()
            alert.messageText = "Replace imported translation?"
            alert.informativeText = "Replace \(url.lastPathComponent) with the selected file?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                self.presentingLibraryAlert = false
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
