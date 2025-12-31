import Foundation
import SwiftUI

struct VerseQuery {
    let bookName: String
    let chapterNumber: Int
    let verseNumber: Int

    var title: String {
        return "\(bookName) \(chapterNumber): \(verseNumber)"
    }

    var bookAndChapter: String {
        return "\(bookName) \(chapterNumber)"
    }
}

class VerseTargetModel: ObservableObject {
    @Published var verseQuery: VerseQuery = .init(bookName: "John", chapterNumber: 3, verseNumber: 16)
}

// MARK: - Books List View
struct BooksListView: View {
    @Binding var selectedBook: String?
    @Binding var chapterCount: Int32

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedBook) {
                Section("Old Testament") {
                    ForEach(Array(bibleBooks.keys.prefix(39)), id: \.self) { bookName in
                        NavigationLink(value: bookName) {
                            HStack {
                                Text(bookName)
                                    .font(.system(size: 14, weight: selectedBook == bookName ? .semibold : .regular))
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    }
                }

                Section("New Testament") {
                    ForEach(Array(bibleBooks.keys.suffix(27)), id: \.self) { bookName in
                        NavigationLink(value: bookName) {
                            HStack {
                                Text(bookName)
                                    .font(.system(size: 14, weight: selectedBook == bookName ? .semibold : .regular))
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedBook) { _, newBook in
                if let book = newBook {
                    chapterCount = Int32(bibleBooks[book]?.last ?? 0)
                    proxy.scrollTo(book, anchor: .center)
                }
            }
            .accessibilityLabel("Bible books list")
        }
    }
}

// MARK: - Chapters List View
struct ChaptersListView: View {
    let selectedBook: String?
    @Binding var selectedChapter: Int?
    let chapterCount: Int32
    let onChapterSelected: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedChapter) {
                if chapterCount > 0 {
                    Section(selectedBook ?? "Chapters") {
                        ForEach(1...Int(chapterCount), id: \.self) { chapter in
                            NavigationLink(value: chapter) {
                                HStack {
                                    Text("\(chapter)")
                                        .font(.system(size: 16, weight: selectedChapter == chapter ? .semibold : .regular))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "Select a Book",
                        systemImage: "book.closed",
                        description: Text("Choose a book from the sidebar to view chapters")
                    )
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedChapter) { _, newChapter in
                if let chapter = newChapter {
                    onChapterSelected(chapter)
                    proxy.scrollTo(chapter, anchor: .center)
                }
            }
            .accessibilityLabel("Chapter list")
        }
    }
}

// MARK: - Search Results View
struct SearchResultsView: View {
    let searchQuery: String
    let primaryResults: [AVerse]
    let secondaryResults: [AVerse]
    let showOnlyPrimary: Bool
    let onVerseSelected: (AVerse) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Search Results for '\(searchQuery)'")
                    .font(.headline)
                Spacer()
                Text("\(primaryResults.count) results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Results
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(primaryResults.enumerated()), id: \.element.verseId) { index, verse in
                        VStack(alignment: .leading, spacing: 8) {
                            // Reference
                            Text("\(verse.bookName) \(verse.chapterNumber):\(verse.verseNumber)")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.blue)

                            // Primary verse
                            Text(verse.verse)
                                .font(.body)
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            // Secondary verse
                            if !showOnlyPrimary, index < secondaryResults.count {
                                Text(secondaryResults[index].verse)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
                        .cornerRadius(8)
                        .onTapGesture {
                            onVerseSelected(verse)
                        }
                        .accessibilityLabel("\(verse.bookName) \(verse.chapterNumber):\(verse.verseNumber)")
                        .accessibilityHint("Tap to project this verse")
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: - Main Content View
struct MainContentView: View {
    @Binding var ask: String
    @Binding var validQuery: Bool
    @Binding var windowOpened: Bool
    @Binding var searchResults: (primary: [AVerse], secondary: [AVerse])?
    @Binding var searchQuery: String?
    @FocusState.Binding var focusedColumn: NavigationColumn?

    let primaryBibleName: String
    let secondaryBibleName: String
    let showOnlyPrimary: Bool
    let onSubmit: () -> Void
    let closeProjector: () -> Void
    let onSearchVerseSelected: (AVerse) -> Void

    @FocusState private var isSearchFieldFocused: Bool
    @EnvironmentObject var verseRowViewModel: VerseRowViewModel

    var body: some View {
        VStack {
            Button(action: closeProjector) {
                Text("Clear")
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .accessibilityLabel("Clear projector")
            .accessibilityHint("Closes the projector window")

            TextField("John 3:16  or  s: his only begotten son  or  m: jesus AND fig", text: $ask)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    onSubmit()
                }
                .modifier(ShakeEffect(shakes: validQuery ? 2 : 0))
                .frame(width: 500, height: 35, alignment: .center)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray, lineWidth: 1))
                .font(.largeTitle)
                .disableAutocorrection(true)
                .accessibilityLabel("Verse search or text search")
                .accessibilityHint("Enter verse reference like John 3:16, or search text with s: prefix")
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FocusSearchField"))) { _ in
                    isSearchFieldFocused = true
                }

            // Show search results if available
            if let results = searchResults, let query = searchQuery {
                SearchResultsView(
                    searchQuery: query,
                    primaryResults: results.primary,
                    secondaryResults: results.secondary,
                    showOnlyPrimary: showOnlyPrimary,
                    onVerseSelected: onSearchVerseSelected
                )
            } else if verseRowViewModel.verseRowData.primaryChapter.isEmpty {
                // Show welcome message when no verse is loaded
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "book.pages")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                    Text("View The Word")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text("Select a book and chapter from the sidebar,\nor type a verse reference above")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("Example: John 3:16  or  s: his only begotten son")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VerseRowView(windowOpened: $windowOpened)
                    .focused($focusedColumn, equals: .verses)
            }

            Spacer()
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .padding()
    }
}

struct ContentView: View {
    @StateObject var verseTargetModel: VerseTargetModel = .init()
    @AppStorage("history") private var history: [String] = ["John 3: 16"]

    var body: some View {
        MainView().environmentObject(verseTargetModel)
    }
}

// Column focus for keyboard navigation
enum NavigationColumn: Hashable {
    case books
    case chapters
    case detail
    case verses
}

struct MainView: View {
    @EnvironmentObject var verseTargetModel: VerseTargetModel
    @StateObject var verseRowViewModel: VerseRowViewModel = .init()
    @StateObject var projectorViewModel: ProjectorViewModel = .init()

    @State private var ask: String = ""
    @State private var selectedBook: String?
    @State private var selectedChapter: Int?
    @State private var windowOpened = false
    @State private var validQuery = true
    @State private var chapterCount: Int32 = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showKeyboardShortcuts = false
    @State private var searchResults: (primary: [AVerse], secondary: [AVerse])? = nil
    @State private var currentSearchQuery: String? = nil
    @State private var isUpdatingFromTextField = false
    @FocusState private var focusedColumn: NavigationColumn?

    @AppStorage("history") private var history: [String] = ["John 3: 16"]
    @AppStorage("showOnlyPrimary") var showOnlyPrimary = false

    // To reload the VerseRowView and ProjectorView if the bible changes in Settings.
    @AppStorage("PrimaryBibleName") private var primaryBibleName: String = bundledPrimaryBibleUrl?.absoluteString ?? ""
    @AppStorage("SecondaryBibleName") private var secondaryBibleName: String = bundledSecondaryBibleUrl?.absoluteString ?? ""

    // Long-lived database connections (reused across queries)
    @State private var biblePrimary: Bible
    @State private var bibleSecondary: Bible

    init() {
        let bibleUrl = BibleUrl()
        _biblePrimary = State(initialValue: Bible(dbUrl: bibleUrl.primaryBibleUrl))
        _bibleSecondary = State(initialValue: Bible(dbUrl: bibleUrl.secondaryBibleUrl))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: Books
            BooksListView(
                selectedBook: $selectedBook,
                chapterCount: $chapterCount
            )
            .focused($focusedColumn, equals: .books)
            .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 250)
        } content: {
            // Content: Chapters (only shown when a book is selected)
            if let selectedBook = selectedBook {
                ChaptersListView(
                    selectedBook: selectedBook,
                    selectedChapter: $selectedChapter,
                    chapterCount: chapterCount,
                    onChapterSelected: { chapter in
                        // Only update if user clicked in sidebar (not programmatic update from text field)
                        if !isUpdatingFromTextField {
                            ask = "\(selectedBook) \(chapter)"
                            // Run processSearchQuery asynchronously to avoid blocking UI
                            Task { @MainActor in
                                processSearchQuery(updateRowView: true, project: false)
                            }
                        }
                    }
                )
                .focused($focusedColumn, equals: .chapters)
                .navigationSplitViewColumnWidth(min: 80, ideal: 100, max: 120)
            }
        } detail: {
            // Detail: Main content
            MainContentView(
                ask: $ask,
                validQuery: $validQuery,
                windowOpened: $windowOpened,
                searchResults: $searchResults,
                searchQuery: $currentSearchQuery,
                focusedColumn: $focusedColumn,
                primaryBibleName: primaryBibleName,
                secondaryBibleName: secondaryBibleName,
                showOnlyPrimary: showOnlyPrimary,
                onSubmit: {
                    processSearchQuery(updateRowView: true)
                    withAnimation(.default) {
                        validQuery = true
                    }
                    focusedColumn = .verses
                },
                closeProjector: closeProjector,
                onSearchVerseSelected: { verse in
                    projectSearchResult(verse: verse)
                }
            )
            .focused($focusedColumn, equals: .detail)
            .environmentObject(projectorViewModel)
            .environmentObject(verseTargetModel)
            .environmentObject(verseRowViewModel)
        }
        .onAppear {
            // Set initial focus to detail column
            focusedColumn = .detail
        }
        .onChange(of: selectedBook) { _, newBook in
            if newBook != nil {
                // Show all columns when book is selected
                columnVisibility = .all
            } else {
                // Hide chapters column when no book selected
                columnVisibility = .doubleColumn
            }
        }
        .contextMenu {
            Text("History")
            Divider()
            ForEach(history, id: \.self) { item in
                Button {
                    ask = item
                    processSearchQuery(updateRowView: false)
                } label: {
                    Text(item)
                }
            }
        }
        .onKeyPress(keys: [.tab]) { press in
            // Check if Shift is pressed
            if press.modifiers.contains(.shift) {
                // Shift+Tab: Navigate left (backward)
                navigateColumnLeft()
                return .handled
            } else {
                // Tab: Navigate right (forward)
                navigateColumnRight()
                return .handled
            }
        }
        .sheet(isPresented: $showKeyboardShortcuts) {
            KeyboardShortcutsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ToggleKeyboardShortcuts"))) { _ in
            showKeyboardShortcuts.toggle()
        }
        .onChange(of: primaryBibleName) { oldValue, newValue in
            // Recreate primary Bible connection when translation changes
            // Note: Old instance will be deallocated by ARC after ongoing queries complete
            if let newUrl = URL(string: newValue) {
                biblePrimary = Bible(dbUrl: newUrl)

                // Reload current verse with new translation
                if verseRowViewModel.verseRowData.primaryChapter.count > 0 {
                    processSearchQuery(updateRowView: true, project: windowOpened)
                }
            }
        }
        .onChange(of: secondaryBibleName) { oldValue, newValue in
            // Recreate secondary Bible connection when translation changes
            // Note: Old instance will be deallocated by ARC after ongoing queries complete
            if let newUrl = URL(string: newValue) {
                bibleSecondary = Bible(dbUrl: newUrl)

                // Reload current verse with new translation
                if verseRowViewModel.verseRowData.primaryChapter.count > 0 {
                    processSearchQuery(updateRowView: true, project: windowOpened)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: selectedBook)
    }
    

    func getChapterCount(bookName: String) {
        selectedBook = bookName
        chapterCount = Int32(bibleBooks[bookName]?.last ?? 0)
    }

    func processSearchQuery(updateRowView: Bool = true, project: Bool = true) {
        // Check if this is a text search or verse query
        guard let searchType = SearchQuery(ask: ask).searchType() else {
            validQuery.toggle()
            return
        }

        switch searchType {
        case .phrase(let searchText, let filter):
            performPhraseSearch(searchText: searchText, filter: filter)
        case .multiTerm(let searchText, let filter):
            performMultiTermSearch(searchText: searchText, filter: filter)
        case .verse(let verseQuery):
            performVerseQuery(verseQuery: verseQuery, updateRowView: updateRowView, project: project)
        }
    }

    func performPhraseSearch(searchText: String, filter: SearchFilter) {
        // Phrase search with optional filter using long-lived connections
        let primaryResults = biblePrimary.searchTextWithFilter(searchQuery: searchText, filter: filter) ?? []
        let secondaryResults = bibleSecondary.searchTextWithFilter(searchQuery: searchText, filter: filter) ?? []

        searchResults = (primary: primaryResults, secondary: secondaryResults)
        currentSearchQuery = searchText

        // Clear the row view data
        verseRowViewModel.verseRowData = VerseRowData(primaryChapter: [], secondaryChapter: [])
    }

    func performMultiTermSearch(searchText: String, filter: SearchFilter) {
        // Parse as expression-based search (with AND/OR/NOT) using long-lived connections
        let parser = SearchParser(query: searchText)
        if let expression = parser.parse() {
            // Use expression-based search
            let primaryResults = biblePrimary.searchWithExpression(expression: expression, filter: filter) ?? []
            let secondaryResults = bibleSecondary.searchWithExpression(expression: expression, filter: filter) ?? []

            searchResults = (primary: primaryResults, secondary: secondaryResults)
            currentSearchQuery = searchText
        } else {
            // Fallback to simple search if parsing fails
            let primaryResults = biblePrimary.searchText(searchQuery: searchText) ?? []
            let secondaryResults = bibleSecondary.searchText(searchQuery: searchText) ?? []

            searchResults = (primary: primaryResults, secondary: secondaryResults)
            currentSearchQuery = searchText
        }

        // Clear the row view data
        verseRowViewModel.verseRowData = VerseRowData(primaryChapter: [], secondaryChapter: [])
    }

    func performVerseQuery(verseQuery: VerseQuery, updateRowView: Bool, project: Bool) {
        // Clear search results when performing verse query
        searchResults = nil
        currentSearchQuery = nil

        if verseQuery.bookName != "" && verseQuery.chapterNumber != 0 {
            // Set flag to prevent onChange handler from re-parsing when updating from text field
            if updateRowView {
                isUpdatingFromTextField = true
            }

            getChapterCount(bookName: verseQuery.bookName)
            selectedChapter = verseQuery.chapterNumber

            // Reset flag after sidebar is updated
            if updateRowView {
                DispatchQueue.main.async {
                    isUpdatingFromTextField = false
                }
            }
        }

        // Try to get verse from primary Bible using long-lived connection
        var primaryText: String?
        if let verseOne = biblePrimary.pickAVerse(verseQuery: verseQuery) {
            primaryText = verseOne.verse
        }

        // Try to get verse from secondary Bible using long-lived connection
        var secondaryText: String?
        if !showOnlyPrimary {
            if let verseTwo = bibleSecondary.pickAVerse(verseQuery: verseQuery) {
                secondaryText = verseTwo.verse
            }
        }

        // If neither Bible has the verse, show error
        if primaryText == nil && secondaryText == nil {
            validQuery.toggle()
            return
        }

        // Title
        let title: String = verseQuery.title

        // History
        if history.count > 22 {
            history.remove(at: 1)
        }
        if !history.contains(title) && (primaryText != nil || secondaryText != nil) {
            history.append(title)
        }

        if (primaryText != nil || secondaryText != nil) && project {
            // Set verse for projector view
            let displayPrimaryText = primaryText ?? secondaryText ?? "\u{200c}"
            // Only show secondary if primary exists AND they're different
            let displaySecondaryText = primaryText != nil ? secondaryText : nil

            projectorViewModel.projectorViewData = ProjectorViewData(
                title: title,
                primaryText: displayPrimaryText,
                secondaryText: displaySecondaryText
            )
            openProjector()
        }

        // Row view needs to set/update only when `ask` is via TextField.
        if updateRowView {
            verseTargetModel.verseQuery = verseQuery // Observable

            // Resetting TextField content
            ask = title

            // Set verse for row view - show whatever chapters are available
            let primaryChapter = biblePrimary.pickAChapter(verseQuery: verseQuery) ?? []
            let secondaryChapter = bibleSecondary.pickAChapter(verseQuery: verseQuery) ?? []

            verseRowViewModel.verseRowData = VerseRowData(
                primaryChapter: primaryChapter, secondaryChapter: secondaryChapter
            )
        }
    }

    func projectSearchResult(verse: AVerse) {
        let verseQuery = VerseQuery(
            bookName: verse.bookName,
            chapterNumber: verse.chapterNumber,
            verseNumber: verse.verseNumber
        )

        // Get verse text from both Bibles using long-lived connections
        var primaryText = verse.verse
        if let verseOne = biblePrimary.pickAVerse(verseQuery: verseQuery) {
            primaryText = verseOne.verse
        }

        var secondaryText: String?
        if !showOnlyPrimary {
            if let verseTwo = bibleSecondary.pickAVerse(verseQuery: verseQuery) {
                secondaryText = verseTwo.verse
            }
        }

        let title = verseQuery.title

        // Set verse for projector view
        projectorViewModel.projectorViewData = ProjectorViewData(
            title: title, primaryText: primaryText, secondaryText: secondaryText
        )
        openProjector()
    }

    func navigateColumnLeft() {
        switch focusedColumn {
        case .verses:
            // Move from verses to detail
            focusedColumn = .detail
        case .detail:
            // Move from detail to chapters (if chapters available)
            if selectedBook != nil {
                focusedColumn = .chapters
            } else {
                focusedColumn = .books
            }
        case .chapters:
            // Move from chapters to books
            focusedColumn = .books
        case .books, .none:
            // Cycle to verses (rightmost)
            focusedColumn = .verses
        }
    }

    func navigateColumnRight() {
        switch focusedColumn {
        case .books:
            // Move from books to chapters (if chapters available)
            if selectedBook != nil {
                focusedColumn = .chapters
            } else {
                focusedColumn = .detail
            }
        case .chapters:
            // Move from chapters to detail
            focusedColumn = .detail
        case .detail:
            // Move from detail to verses
            focusedColumn = .verses
        case .verses, .none:
            // Cycle back to books (leftmost)
            focusedColumn = .books
        }
    }

    func openProjector() {
        // Check if window already exists
        if NSApplication.shared.windows.contains(where: { $0.title == "Projector" }) {
            // Window exists, just update the flag and return
            windowOpened = true
            return
        }

        // Only create new window if content is valid and no window exists
        if !windowOpened && projectorViewModel.projectorViewData.primaryText != "?" {
            // Set flag immediately to prevent duplicate window creation
            windowOpened = true
            ProjectorView(windowOpened: $windowOpened)
                .environmentObject(projectorViewModel)
                .openNewWindow(with: "Projector")
        }
    }

    func closeProjector() {
        // Close window first, then update flag
        if let projectorWindow = NSApplication.shared.windows.first(where: { $0.title == "Projector" }) {
            projectorWindow.close()
        }
        windowOpened = false
    }
}

struct ShakeEffect: GeometryEffect {
    func effectValue(size: CGSize) -> ProjectionTransform {
        return ProjectionTransform(
            CGAffineTransform(translationX: -30 * sin(position * 2 * .pi), y: 0)
        )
    }

    init(shakes: Int) {
        position = CGFloat(shakes)
    }

    var position: CGFloat
    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }
}

// MARK: - Keyboard Shortcuts View
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) var dismiss

    let searchTips: [(category: String, items: [(example: String, description: String)])] = [
        ("Verse Reference", [
            ("John 3:16", "Go to specific verse"),
            ("gen 1:1", "Book name abbreviation works"),
            ("1 cor 13", "Goes to chapter 13, verse 1")
        ]),
        ("Phrase Search (s:)", [
            ("s: his only begotten son", "Exact phrase match"),
            ("s: in the beginning", "Finds exact phrase"),
            ("s: ot: the lord", "Search Old Testament only"),
            ("s: nt: believe", "Search New Testament only"),
            ("s: john: light", "Search in book of John")
        ]),
        ("Multi-term Search (m:)", [
            ("m: jesus AND mary", "Both words must appear"),
            ("m: jesus OR christ", "Either word appears"),
            ("m: love AND NOT hate", "Include love, exclude hate"),
            ("m: god AND (love OR mercy)", "Grouping with parentheses"),
            ("m: nt: faith AND hope", "Multi-term in New Testament"),
            ("m: john: light AND darkness", "Multi-term in specific book")
        ])
    ]

    let keyboardShortcuts: [(category: String, items: [(keys: String, description: String)])] = [
        ("Verse Navigation", [
            ("↑ / ↓", "Previous/next verse"),
            ("⌘ ↑ / ⌘ ↓", "Jump 5 verses"),
            ("⌥ ↑ / ⌥ ↓", "Previous/next chapter"),
            ("Page Up/Down", "Jump 10 verses"),
            ("Home / End", "First/last verse"),
            ("Space", "Toggle projector"),
            ("Tab", "Cycle through columns")
        ]),
        ("General", [
            ("⌘ L", "Focus search field"),
            ("Return", "Search/display verse"),
            ("Escape", "Clear projector"),
            ("⌘ /", "Show this help"),
            ("⌘ ,", "Open Settings"),
            ("⌘ Q", "Quit application")
        ])
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Help")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Two-column content
            HStack(alignment: .top, spacing: 0) {
                // Left column: Search Tips
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Search Tips")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.bottom, 4)

                        ForEach(searchTips, id: \.category) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.category)
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                VStack(spacing: 6) {
                                    ForEach(section.items, id: \.example) { item in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.example)
                                                .font(.system(.body, design: .monospaced))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color(NSColor.controlBackgroundColor))
                                                .cornerRadius(4)
                                                .frame(maxWidth: .infinity, alignment: .leading)

                                            Text(item.description)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .padding(.leading, 8)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity)

                Divider()

                // Right column: Keyboard Shortcuts
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Keyboard Shortcuts")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.bottom, 4)

                        ForEach(keyboardShortcuts, id: \.category) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.category)
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                VStack(spacing: 6) {
                                    ForEach(section.items, id: \.keys) { shortcut in
                                        HStack(spacing: 12) {
                                            Text(shortcut.keys)
                                                .font(.system(.body, design: .monospaced))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color(NSColor.controlBackgroundColor))
                                                .cornerRadius(4)
                                                .frame(width: 100, alignment: .leading)

                                            Text(shortcut.description)
                                                .font(.body)
                                                .foregroundColor(.secondary)

                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 900, height: 600)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
