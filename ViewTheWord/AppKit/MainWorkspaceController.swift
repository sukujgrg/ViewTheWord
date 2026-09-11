import AppKit
import Combine

/// One passage workspace. Model snapshots never request focus.
/// Live output belongs to the shared LiveProjectionController.
@MainActor
final class MainWorkspaceController: NSViewController {
    let tabID = UUID()
    let navigation: VerseTargetModel
    let liveProjection: LiveProjectionController
    var projector: ProjectorViewModel { liveProjection.projector }
    var windowOpened: Bool { liveProjection.windowOpened }
    var onOpenInNewTab: ((VerseReference?) -> Void)?
    let history: HistoryStore
    let bookmarks: BookmarkStore
    let library: BibleLibrary
    let defaults: UserDefaults
    let updates: AppUpdateController?
    private(set) var translations: PassageTranslations

    let testamentControl = NSSegmentedControl(labels: BibleTestament.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    lazy var books = NativeSidebarController(label: "Bible books", header: testamentControl)
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
    let dismissProjectionMessageButton = NSButton(title: "Dismiss", target: nil, action: nil)
    let emptyLabel = NSTextField(wrappingLabelWithString: "Choose a book and chapter, or enter a reference in Search.")
    let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    let blankButton = NSButton(title: "Blank", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let loadMoreButton = NSButton(title: "Load more results", target: nil, action: nil)
    let clearBookmarksButton = NSButton(title: "Clear", target: nil, action: nil)
    let clearHistoryButton = NSButton(title: "Clear", target: nil, action: nil)
    let viewOptions = NSPopUpButton(frame: .zero, pullsDown: true)
    let projectionOptions = NSPopUpButton(frame: .zero, pullsDown: true)
    let resultsHeader = NSStackView()
    let footer = NSStackView()
    let preview = NSPopover()
    var searchToolbarItem: NSSearchToolbarItem?

    private(set) var browsedBook: String?
    private(set) var browsedTestament = BibleTestament.oldTestament
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
         translations: PassageTranslations? = nil, liveProjection: LiveProjectionController? = nil,
         updates: AppUpdateController? = nil) {
        self.navigation = navigation ?? VerseTargetModel()
        let liveProjection = liveProjection ?? LiveProjectionController(projector: projector, library: library, defaults: defaults)
        self.liveProjection = liveProjection
        self.history = history ?? .shared
        self.bookmarks = bookmarks ?? .shared
        self.library = liveProjection.library
        self.defaults = liveProjection.defaults
        self.translations = translations ?? liveProjection.library.defaultTranslations(liveProjection.defaults)
        self.updates = updates
        super.init(nibName: nil, bundle: nil)
        liveProjection.updateSources(sources, from: tabID)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { renderTask?.cancel() }

    var primaryOnly: Bool { translations.primaryOnly }
    var sources: BibleSources? { library.sources(for: translations) }
    var visibleSearchPage: SearchPage? {
        guard let sources, let page = navigation.searchPage, page.sources == sources else { return nil }
        return page
    }

    func setTranslations(_ selection: PassageTranslations) {
        guard !shuttingDown else { return }
        guard translations != selection else { return }
        let priorSources = sources
        translations = selection
        // Remember explicit choices for the next first passage. Open tabs keep
        // their own values and never read these preferences during rendering.
        defaults.set(selection.primary?.absoluteString, forKey: AppDefaultsKey.primaryBibleName)
        defaults.set(selection.secondary?.absoluteString, forKey: AppDefaultsKey.secondaryBibleName)
        defaults.set(selection.primaryOnly, forKey: AppDefaultsKey.showOnlyPrimary)
        if sources != priorSources {
            liveProjection.updateSources(sources, from: tabID)
            if isViewLoaded {
                previousSources = sources
                refreshSources()
            }
        }
        scheduleRender()
    }

    func setSecondaryTranslation(_ url: URL?) {
        var selection = translations
        if let url { selection.secondary = url }
        selection.primaryOnly = url == nil
        setTranslations(selection)
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
        for publisher in [navigation.objectWillChange, liveProjection.objectWillChange, projector.objectWillChange, history.objectWillChange,
                          bookmarks.objectWillChange, library.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
        updates?.objectWillChange
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
            guard let self, self.visibleSearchPage != nil else { return }
            self.searchSelection = reference
            self.scheduleRender()
        }
        verses.onToggle = { [weak self] reference in
            guard let self else { return }
            if self.windowOpened && self.projector.projectionOwner?.reference == reference &&
                self.liveProjection.source?.sources == self.sources { self.closeProjector() }
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
        savedBookmarks.onRemove = { [weak self] node in
            guard let self, let reference = node.reference else { return }
            self.bookmarks.remove(reference, undoManager: self.view.window?.undoManager)
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
        if previousSources != sources {
            self.previousSources = sources
            liveProjection.updateSources(sources, from: tabID)
            refreshSources()
        }
        let bookNames = browsedTestament.bookNames
        let testamentChanged = books.nodes.first?.book != bookNames.first
        testamentControl.selectedSegment = browsedTestament.rawValue
        books.apply(bookNames.map { SidebarNode(id: "book-\($0)", title: $0, book: $0) },
                    selectionID: browsedBook.map { "book-\($0)" })
        if testamentChanged && books.outline.selectedRow < 0 { books.outline.scrollRowToVisible(0) }
        let current = navigation.refreshReference
        let selectedChapter = current.flatMap { reference in
            reference.book == browsedBook ? VerseReference(book: reference.book, chapter: reference.chapter, verse: 1) : nil
        }
        chapters.apply(book: browsedBook, selection: selectedChapter)
        chapterTitle.stringValue = browsedBook ?? "Chapters"
        renderSaved()
        renderSearchField()
        renderTranslationPickers(sources)
        if let sources, let page = visibleSearchPage {
            let rows = page.hits.map { hit in
                var row = makeVerseRow(hit.pair, sources: sources)
                let matches = [(hit.matchedPrimary, Optional(sources.primary)), (hit.matchedSecondary, sources.secondary)]
                    .compactMap { matched, url in matched ? url.map(BibleTranslation.name) : nil }.joined(separator: ", ")
                row.heading = hit.pair.reference.verseQuery.title + "  ·  " + matches
                return row
            }
            if !rows.contains(where: { $0.reference == searchSelection }) { searchSelection = rows.first?.reference }
            verses.activatesOnSelection = false
            verses.apply(rows: rows, selection: searchSelection, style: .results(fontSize: rowFontSize, dual: sources.secondary != nil),
                         enabled: !navigation.isLoading, scrollRequest: page.id)
            referenceTitle.stringValue = "Search results"
            resultLabel.stringValue = "\(page.hits.count)\(page.hasMore ? "+" : "") results for “\(page.request.text)”"
            resultsHeader.isHidden = false
            loadMoreButton.isHidden = !page.hasMore
            loadMoreButton.isEnabled = !navigation.isLoading
            emptyLabel.stringValue = "No matches. Try another phrase or change the search mode."
        } else if let sources {
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
        } else {
            verses.apply(rows: [], selection: nil, style: .verses(fontSize: rowFontSize, dual: false), enabled: false)
            referenceTitle.stringValue = "Bible Library"
            resultsHeader.isHidden = true
            loadMoreButton.isHidden = true
            emptyLabel.stringValue = BibleLibraryError.empty.localizedDescription
        }
        renderTabHeading(sources)
        emptyLabel.isHidden = !verses.rows.isEmpty
        renderStatus()
        renderUpdateToolbar()
        rebuildOptionMenus()
        let messages = [navigation.message, liveProjection.message, bookmarks.issue, history.issue].compactMap { $0 }
        messageLabel.stringValue = messages.joined(separator: "  ")
        messageLabel.toolTip = messageLabel.stringValue
        footer.isHidden = messages.isEmpty
        dismissProjectionMessageButton.isHidden = liveProjection.message == nil
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
        clearBookmarksButton.isEnabled = !bookmarks.entries.isEmpty
        clearHistoryButton.isEnabled = !weeks.isEmpty
    }

    func browse(_ book: String) {
        guard book != browsedBook else { return }
        navigation.cancelLoading(clearSearch: true)
        revealBook(book)
        searchSelection = nil
        render()
    }

    @objc func changeTestament(_ sender: NSSegmentedControl) {
        guard let testament = BibleTestament(rawValue: sender.selectedSegment), testament != browsedTestament else { return }
        // Filtering books leaves the prepared passage and shared live output alone.
        browsedTestament = testament
        render()
    }

    func navigate(to reference: VerseReference, project: Bool = false, recordHistory: Bool = false,
                  updateDraft: Bool = true, focusVerses: Bool = true, updateBrowsing: Bool = true) {
        guard let sources else { showEmptyLibrary(); return }
        let originalDraft = draft
        let interactionRevision = search.interactionRevision
        let responder = view.window?.firstResponder
        let wasEditingSearch = search.isSendingSubmission || (responder != nil && responder === search.field.currentEditor())
        let intent = project ? liveProjection.beginIntent(from: tabID, sources: sources, using: navigation) : nil
        navigation.navigate(to: reference, sources: sources, project: project, onProjectionCancelled: { [weak self] in
            if let intent { self?.liveProjection.finishIntent(intent) }
        }) { [weak self] outcome in
            guard let self else { return }
            guard case .success(let result) = outcome else {
                if let intent { self.liveProjection.finishIntent(intent) }
                self.scheduleRender()
                return
            }
            if updateBrowsing { self.revealBook(result.reference.book) }
            if updateDraft && self.draft == originalDraft && self.search.interactionRevision == interactionRevision {
                self.draft = result.reference.verseQuery.title
                if focusVerses && self.focusUnchanged(from: responder, wasEditingSearch: wasEditingSearch) { self.focus(.verses) }
            }
            if recordHistory && result.requestedAvailable { self.history.append(reference.verseQuery.title) }
            if let intent {
                if let projection = result.projection { self.liveProjection.publish(projection, intent: intent) }
                else { self.liveProjection.finishIntent(intent) }
            }
            self.scheduleRender()
        }
        scheduleRender()
    }

    func submitSearch() {
        guard let sources else { showEmptyLibrary(); return }
        do {
            switch try SearchQuery(ask: draft).searchType(mode: searchMode) {
            case .verse(let query):
                guard let reference = VerseReference(query) else { throw QueryError.invalidReference }
                navigate(to: reference, project: true, recordHistory: true)
            case .text(let request):
                searchSelection = nil
                let submittedDraft = draft
                let interactionRevision = search.interactionRevision
                let responder = view.window?.firstResponder
                let wasEditingSearch = search.isSendingSubmission || (responder != nil && responder === search.field.currentEditor())
                navigation.search(request, sources: sources) { [weak self] outcome in
                    guard case .success = outcome, let self, self.draft == submittedDraft,
                          self.search.interactionRevision == interactionRevision,
                          self.focusUnchanged(from: responder, wasEditingSearch: wasEditingSearch) else { return }
                    self.focus(.verses)
                }
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
            navigate(to: reference, updateDraft: false, focusVerses: false, updateBrowsing: false)
        }
        renderSearchField()
        scheduleRender()
        focusSearch(nil)
    }

    func activateVerse(_ reference: VerseReference) {
        guard let sources else { showEmptyLibrary(); return }
        if visibleSearchPage != nil {
            liveProjection.requestProjection(owner: .searchResult(reference), from: tabID, sources: sources, using: navigation)
        } else {
            guard let projection = navigation.prepareRowProjection(reference, sources: sources) else { return }
            revealBook(reference.book)
            draft = reference.verseQuery.title
            liveProjection.publishRow(projection, from: tabID)
        }
    }

    func refreshSources() {
        guard let sources else { showEmptyLibrary(); return }
        if let request = navigation.searchRequest { navigation.search(request, sources: sources) }
        else if let reference = navigation.refreshReference {
            navigate(to: reference, updateDraft: false, focusVerses: false, updateBrowsing: false)
        }
        else { navigation.cancelLoading() }
    }

    private func showEmptyLibrary() {
        navigation.cancelAll()
        // The empty-state view owns this explanation; do not retain a stale
        // database error after a catalog change or duplicate it in the footer.
        navigation.message = nil
        scheduleRender()
    }

    private func revealBook(_ book: String) {
        browsedBook = book
        browsedTestament = BibleTestament(book: book)
    }

    private func focusUnchanged(from responder: NSResponder?, wasEditingSearch: Bool) -> Bool {
        guard let window = view.window else { return false }
        if window.firstResponder === responder { return true }
        // Return can temporarily give first responder to the window and then
        // restore the same search editor without starting a new editing session.
        return wasEditingSearch && (window.firstResponder === search.field || window.firstResponder === window ||
                                    window.firstResponder === search.field.currentEditor())
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
        guard !shuttingDown else { return }
        shuttingDown = true
        liveProjection.detachTab(tabID)
        navigation.cancelAll()
        preview.performClose(nil)
        renderTask?.cancel()
        subscriptions.removeAll()
    }

    private func presentLibraryAlertIfNeeded() {
        guard !presentingLibraryAlert, let window = view.window, window.isKeyWindow,
              let request = library.claimAlert(for: .main) else { return }
        presentingLibraryAlert = true
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.message
        let replacing: Bool
        if case .replacement = request.content {
            replacing = true
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
        } else {
            replacing = false
            alert.addButton(withTitle: "OK")
        }
        alert.beginSheetModal(for: window) { [weak self, library] response in
            self?.presentingLibraryAlert = false
            library.completeAlert(request.id, replaceExisting: replacing && response == .alertFirstButtonReturn)
            self?.scheduleRender()
        }
    }
}
