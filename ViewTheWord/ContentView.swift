import Foundation
import SwiftUI
import AppKit

private extension View {
    @ViewBuilder
    func applyWindowSurfaceBackground() -> some View {
        if #available(macOS 15.0, *) {
            containerBackground(.thinMaterial, for: .window)
        } else {
            background(.thinMaterial)
        }
    }
}

private struct NativePersistentVSplitView<Top: View, Bottom: View>: NSViewControllerRepresentable {
    let autosaveName: String
    let topMinHeight: CGFloat
    let bottomMinHeight: CGFloat
    let top: Top
    let bottom: Bottom

    init(
        autosaveName: String,
        topMinHeight: CGFloat = 180,
        bottomMinHeight: CGFloat = 120,
        @ViewBuilder top: () -> Top,
        @ViewBuilder bottom: () -> Bottom
    ) {
        self.autosaveName = autosaveName
        self.topMinHeight = topMinHeight
        self.bottomMinHeight = bottomMinHeight
        self.top = top()
        self.bottom = bottom()
    }

    final class Coordinator {
        let splitController: NSSplitViewController
        let topHost: NSHostingController<Top>
        let bottomHost: NSHostingController<Bottom>

        init(
            top: Top,
            bottom: Bottom,
            autosaveName: String,
            topMinHeight: CGFloat,
            bottomMinHeight: CGFloat
        ) {
            splitController = NSSplitViewController()
            splitController.splitView.isVertical = false
            splitController.splitView.dividerStyle = .thin
            splitController.splitView.autosaveName = NSSplitView.AutosaveName(autosaveName)

            topHost = NSHostingController(rootView: top)
            bottomHost = NSHostingController(rootView: bottom)

            let topItem = NSSplitViewItem(viewController: topHost)
            topItem.canCollapse = false
            topItem.minimumThickness = topMinHeight

            let bottomItem = NSSplitViewItem(viewController: bottomHost)
            bottomItem.canCollapse = false
            bottomItem.minimumThickness = bottomMinHeight

            splitController.addSplitViewItem(topItem)
            splitController.addSplitViewItem(bottomItem)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            top: top,
            bottom: bottom,
            autosaveName: autosaveName,
            topMinHeight: topMinHeight,
            bottomMinHeight: bottomMinHeight
        )
    }

    func makeNSViewController(context: Context) -> NSSplitViewController {
        context.coordinator.splitController
    }

    func updateNSViewController(_ nsViewController: NSSplitViewController, context: Context) {
        context.coordinator.topHost.rootView = top
        context.coordinator.bottomHost.rootView = bottom
    }
}

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

    private let allBooks = Array(bibleBooks.keys)
    private let oldTestamentHeaderColor: Color = .brown
    private let newTestamentHeaderColor: Color = .mint

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedBook) {
                Section {
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
                } header: {
                    Text("Old Testament")
                        .foregroundStyle(oldTestamentHeaderColor)
                }

                Section {
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
                } header: {
                    Text("New Testament")
                        .foregroundStyle(newTestamentHeaderColor)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(.regularMaterial)
            .onChange(of: selectedBook) { _, newBook in
                if let book = newBook {
                    chapterCount = Int32(bibleBooks[book]?.last ?? 0)
                    proxy.scrollTo(book, anchor: .center)
                }
            }
            .onKeyPress { keyPress in
                // Handle Page Up/Down for book navigation
                if keyPress.characters == "\u{F72C}" { // Page Up
                    navigateBooks(offset: -10, proxy: proxy)
                    return .handled
                }

                if keyPress.characters == "\u{F72D}" { // Page Down
                    navigateBooks(offset: 10, proxy: proxy)
                    return .handled
                }

                return .ignored
            }
            .accessibilityLabel("Bible books list")
        }
    }

    private func navigateBooks(offset: Int, proxy: ScrollViewProxy) {
        guard let currentBook = selectedBook,
              let currentIndex = allBooks.firstIndex(of: currentBook) else {
            // If no book selected, start from beginning or end based on direction
            if offset > 0, let firstBook = allBooks.first {
                selectedBook = firstBook
                proxy.scrollTo(firstBook, anchor: .center)
            } else if offset < 0, let lastBook = allBooks.last {
                selectedBook = lastBook
                proxy.scrollTo(lastBook, anchor: .center)
            }
            return
        }

        let newIndex = currentIndex + offset
        if newIndex >= 0 && newIndex < allBooks.count {
            let newBook = allBooks[newIndex]
            selectedBook = newBook
            proxy.scrollTo(newBook, anchor: .center)
        } else if newIndex < 0 {
            // Jump to first book
            let firstBook = allBooks[0]
            selectedBook = firstBook
            proxy.scrollTo(firstBook, anchor: .center)
        } else {
            // Jump to last book
            let lastBook = allBooks[allBooks.count - 1]
            selectedBook = lastBook
            proxy.scrollTo(lastBook, anchor: .center)
        }
    }
}

// MARK: - Chapters List View
struct ChaptersListView: View {
    let selectedBook: String?
    @Binding var selectedChapter: Int?
    let chapterCount: Int32
    let onChapterSelected: (Int) -> Void
    let bookmarkEntries: [BookmarkStore.Entry]
    let onSelectBookmarkItem: (BookmarkStore.Entry) -> Void
    let onRemoveBookmarkItem: (BookmarkStore.Entry) -> Void
    let onClearBookmarks: () -> Void
    let historySections: [HistoryStore.WeekSection]
    let onSelectHistoryItem: (String) -> Void
    let onClearHistory: () -> Void

    @State private var selectedBookmarkID: String?
    @State private var selectedHistoryID: String?
    @State private var bookmarkTapActivatedID: String?
    @State private var historyTapActivatedID: String?

    private let minChapterHeight: CGFloat = 180
    private let minBottomPaneHeight: CGFloat = 180
    private let minBookmarkHeight: CGFloat = 120
    private let minHistoryHeight: CGFloat = 120
    private let chapterColumnBookHeaderColor: Color = .orange
    private let secondColumnCornerRadius: CGFloat = 12

    var body: some View {
        NativePersistentVSplitView(
            autosaveName: AppDefaultsKey.chapterHistorySplitAutosaveName,
            topMinHeight: minChapterHeight,
            bottomMinHeight: minBottomPaneHeight
        ) {
            chapterList
        } bottom: {
            bookmarkAndHistorySplit
        }
        .clipShape(RoundedRectangle(cornerRadius: secondColumnCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: secondColumnCornerRadius, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var bookmarkAndHistorySplit: some View {
        NativePersistentVSplitView(
            autosaveName: AppDefaultsKey.bookmarkHistorySplitAutosaveName,
            topMinHeight: minBookmarkHeight,
            bottomMinHeight: minHistoryHeight
        ) {
            bookmarkList
        } bottom: {
            historyList
        }
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedChapter) {
                if chapterCount > 0 {
                    Section {
                        ForEach(1...Int(chapterCount), id: \.self) { chapter in
                            Text("Chapter \(chapter)")
                                .font(.system(size: 13, weight: selectedChapter == chapter ? .semibold : .regular))
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .tag(chapter)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        }
                    } header: {
                        Text(selectedBook ?? "Chapters")
                            .foregroundStyle(chapterColumnBookHeaderColor)
                    }
                } else {
                    ContentUnavailableView(
                        "Select a Book",
                        systemImage: "book.closed",
                        description: Text("Choose a book from the sidebar to view chapters")
                    )
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(.regularMaterial)
            .onChange(of: selectedChapter) { _, newChapter in
                if let chapter = newChapter {
                    onChapterSelected(chapter)
                    proxy.scrollTo(chapter, anchor: .center)
                }
            }
            .onKeyPress { keyPress in
                // Handle Page Up/Down for chapter navigation
                if keyPress.characters == "\u{F72C}" { // Page Up
                    navigateChapters(offset: -10, proxy: proxy)
                    return .handled
                }

                if keyPress.characters == "\u{F72D}" { // Page Down
                    navigateChapters(offset: 10, proxy: proxy)
                    return .handled
                }

                return .ignored
            }
            .accessibilityLabel("Chapter list")
        }
    }

    private var bookmarkList: some View {
        let displayedBookmarks = Array(bookmarkEntries.reversed())

        return List(selection: $selectedBookmarkID) {
            Section {
                if displayedBookmarks.isEmpty {
                    Text("No bookmarks yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayedBookmarks) { entry in
                        Button {
                            bookmarkTapActivatedID = entry.id
                            selectedBookmarkID = entry.id
                            onSelectBookmarkItem(entry)
                        } label: {
                            Text(entry.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .tag(entry.id)
                        .contextMenu {
                            Button("Remove Bookmark", role: .destructive) {
                                onRemoveBookmarkItem(entry)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Bookmarks")
                    Spacer()
                    Button("Clear", action: onClearBookmarks)
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .disabled(displayedBookmarks.isEmpty)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .onChange(of: selectedBookmarkID) { _, newID in
            if bookmarkTapActivatedID == newID {
                bookmarkTapActivatedID = nil
                return
            }
            guard let newID,
                  let selectedEntry = bookmarkEntries.first(where: { $0.id == newID })
            else { return }
            onSelectBookmarkItem(selectedEntry)
        }
        .onChange(of: bookmarkEntries.map(\.id)) { _, currentIDs in
            guard let selectedBookmarkID else { return }
            if !currentIDs.contains(selectedBookmarkID) {
                self.selectedBookmarkID = nil
            }
        }
        .accessibilityLabel("Bookmarks list")
    }

    private var historyList: some View {
        List(selection: $selectedHistoryID) {
            Section {
                if historySections.isEmpty {
                    Text("No recent verse history")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(historySections) { section in
                        Text(section.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        ForEach(section.items) { entry in
                            Button {
                                historyTapActivatedID = entry.id
                                selectedHistoryID = entry.id
                                onSelectHistoryItem(entry.title)
                            } label: {
                                Text(entry.title)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .tag(entry.id)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("History")
                    Spacer()
                    Button("Clear", action: onClearHistory)
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        .disabled(historySections.isEmpty)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .onChange(of: selectedHistoryID) { _, newID in
            if historyTapActivatedID == newID {
                historyTapActivatedID = nil
                return
            }
            guard let newID else { return }
            for section in historySections {
                if let entry = section.items.first(where: { $0.id == newID }) {
                    onSelectHistoryItem(entry.title)
                    return
                }
            }
        }
        .onChange(of: historySections.flatMap(\.items).map(\.id)) { _, currentIDs in
            guard let selectedHistoryID else { return }
            if !currentIDs.contains(selectedHistoryID) {
                self.selectedHistoryID = nil
            }
        }
        .accessibilityLabel("History list")
    }

    private func navigateChapters(offset: Int, proxy: ScrollViewProxy) {
        guard chapterCount > 0 else { return }

        let current = selectedChapter ?? 1
        let newChapter = current + offset

        if newChapter >= 1 && newChapter <= chapterCount {
            selectedChapter = newChapter
            proxy.scrollTo(newChapter, anchor: .center)
        } else if newChapter < 1 {
            // Jump to first chapter
            selectedChapter = 1
            proxy.scrollTo(1, anchor: .center)
        } else {
            // Jump to last chapter
            selectedChapter = Int(chapterCount)
            proxy.scrollTo(Int(chapterCount), anchor: .center)
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
            .background(.thinMaterial)

            Divider()

            // Results
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(primaryResults.indices, id: \.self) { index in
                        let verse = primaryResults[index]
                        SearchResultRowView(
                            verse: verse,
                            secondaryVerse: (!showOnlyPrimary && index < secondaryResults.count) ? secondaryResults[index].verse : nil,
                            onTap: { onVerseSelected(verse) }
                        )
                    }
                }
                .padding()
            }
        }
    }
}

private struct SearchResultRowView: View {
    let verse: AVerse
    let secondaryVerse: String?
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(verse.bookName) \(verse.chapterNumber):\(verse.verseNumber)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)

            Text(verse.verse)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let secondaryVerse {
                Text(secondaryVerse)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
        .onTapGesture(perform: onTap)
        .accessibilityLabel("\(verse.bookName) \(verse.chapterNumber):\(verse.verseNumber)")
        .accessibilityHint("Tap to project this verse")
    }
}

// MARK: - Main Content View
struct MainContentView: View {
    @Binding var ask: String
    @Binding var queryValidationToken: Int
    @Binding var windowOpened: Bool
    @Binding var searchResults: (primary: [AVerse], secondary: [AVerse])?
    @Binding var searchQuery: String?
    @Binding var showOnlyPrimary: Bool
    @FocusState.Binding var focusedColumn: NavigationColumn?

    let onSubmit: () -> Void
    let closeProjector: () -> Void
    let onSearchVerseSelected: (AVerse) -> Void
    let onRowVerseProject: (Int) -> Void
    let onAddBookmark: (VerseReference) -> Void
    let onRemoveBookmark: (VerseReference) -> Void
    let isBookmarked: (VerseReference) -> Bool

    @FocusState private var isSearchFieldFocused: Bool
    @EnvironmentObject var verseRowViewModel: VerseRowViewModel
    @AppStorage(AppDefaultsKey.transparentBackground) private var transparentBackground = false
    @AppStorage(AppDefaultsKey.preferDarkMode) private var preferDarkMode = false
    @AppStorage(AppDefaultsKey.projectorTextAlignment) private var projectorTextAlignmentRaw = ProjectorTextAlignmentMode.center.rawValue
    @AppStorage(AppDefaultsKey.projectorReadingDirection) private var projectorReadingDirectionRaw = ProjectorReadingDirectionMode.auto.rawValue

    var body: some View {
        VStack {
            ProjectionControlsRowView(
                transparentBackground: $transparentBackground,
                projectorTextAlignmentRaw: $projectorTextAlignmentRaw,
                projectorReadingDirectionRaw: $projectorReadingDirectionRaw
            )

            ViewThatFits(in: .horizontal) {
                regularSearchControls
                compactSearchControls
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
                VerseRowView(
                    windowOpened: $windowOpened,
                    onProjectVerse: { index in
                        onRowVerseProject(index)
                    },
                    onStopProjection: {
                        closeProjector()
                    },
                    onAddBookmark: onAddBookmark,
                    onRemoveBookmark: onRemoveBookmark,
                    isBookmarked: isBookmarked
                )
                .focused($focusedColumn, equals: .verses)
            }

            Spacer()
        }
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .padding()
        .onExitCommand(perform: closeProjector)
    }

    private var regularSearchControls: some View {
        HStack(alignment: .center, spacing: 12) {
            appearanceToggle
            Spacer(minLength: 0)
            searchField
                .frame(width: 275, height: 35, alignment: .center)
            Spacer(minLength: 0)
            primaryOnlyToggle
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var compactSearchControls: some View {
        HStack(alignment: .center, spacing: 12) {
            searchField
                .frame(minWidth: 160, maxWidth: .infinity, minHeight: 35, maxHeight: 35)

            Menu {
                Toggle("Dark Mode", isOn: $preferDarkMode)
                Toggle("Primary Only", isOn: $showOnlyPrimary)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .accessibilityLabel("View options")
            }
            .controlSize(.small)
            .help("View options")
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var appearanceToggle: some View {
        Toggle("Dark Mode", isOn: $preferDarkMode)
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Use dark appearance for the app")
            .fixedSize()
    }

    private var primaryOnlyToggle: some View {
        Toggle("Primary Only", isOn: $showOnlyPrimary)
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Show only the primary translation in verse and search results")
            .fixedSize()
    }

    private var searchField: some View {
        TextField(
            "",
            text: $ask,
            prompt: Text("John 3:16  or  s: phrase  or  m: words")
                .font(.body)
                .foregroundStyle(.secondary)
        )
        .textFieldStyle(.plain)
        .focusEffectDisabled()
        .focused($isSearchFieldFocused)
        .onSubmit {
            onSubmit()
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            // Handle Up/Down arrows when text field is focused.
            if isSearchFieldFocused {
                if press.key == .downArrow {
                    focusedColumn = .verses
                    return .handled
                } else if press.key == .upArrow {
                    focusedColumn = .chapters
                    return .handled
                }
            }
            return .ignored
        }
        .modifier(ShakeEffect(shakes: queryValidationToken))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSearchFieldFocused
                        ? Color.accentColor.opacity(0.9)
                        : Color.secondary.opacity(0.45),
                    lineWidth: isSearchFieldFocused ? 1.4 : 1
                )
        )
        .font(.largeTitle)
        .disableAutocorrection(true)
        .accessibilityLabel("Verse search or text search")
        .accessibilityHint("Enter verse reference like John 3:16, or search text with s: prefix")
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            isSearchFieldFocused = true
        }
        .layoutPriority(1)
    }
}

struct ContentView: View {
    @StateObject var verseTargetModel: VerseTargetModel = .init()

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

@MainActor
struct MainView: View {
    @EnvironmentObject var verseTargetModel: VerseTargetModel
    @StateObject var verseRowViewModel: VerseRowViewModel = .init()
    @StateObject var projectorViewModel: ProjectorViewModel = .init()

    @State private var ask: String = ""
    @State private var selectedBook: String?
    @State private var selectedChapter: Int?
    @State private var windowOpened = false
    @State private var queryValidationToken = 0
    @State private var chapterCount: Int32 = 0
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showKeyboardShortcuts = false
    @State private var searchResults: (primary: [AVerse], secondary: [AVerse])? = nil
    @State private var currentSearchQuery: String? = nil
    @State private var programmaticChapterSelection: Int?
    @FocusState private var focusedColumn: NavigationColumn?

    @StateObject private var historyStore = HistoryStore.shared
    @StateObject private var bookmarkStore = BookmarkStore.shared
    @AppStorage(AppDefaultsKey.showOnlyPrimary) var showOnlyPrimary = false

    @AppStorage(AppDefaultsKey.transparentBackground) private var transparentBackground = false

    // To reload the VerseRowView and ProjectorView if the bible changes in Settings.
    @AppStorage(AppDefaultsKey.primaryBibleName) private var primaryBibleName: String = bundledPrimaryBibleUrl?.absoluteString ?? ""
    @AppStorage(AppDefaultsKey.secondaryBibleName) private var secondaryBibleName: String = bundledSecondaryBibleUrl?.absoluteString ?? ""

    // Long-lived database connections (reused across queries)
    @State private var biblePrimary: Bible
    @State private var bibleSecondary: Bible
    @State private var searchTask: Task<Void, Never>?
    @State private var activeSearchID = UUID()

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
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } content: {
            // Content: Chapters + History (always visible; chapters depend on selected book)
            ChaptersListView(
                selectedBook: selectedBook,
                selectedChapter: $selectedChapter,
                chapterCount: chapterCount,
                onChapterSelected: { chapter in
                    // Ignore chapter changes that were set programmatically while syncing the sidebar.
                    if programmaticChapterSelection == chapter {
                        programmaticChapterSelection = nil
                        return
                    }

                    guard let selectedBook else {
                        return
                    }
                    ask = "\(selectedBook) \(chapter)"
                    processSearchQuery(updateRowView: true, project: false, recordHistory: false)
                },
                bookmarkEntries: bookmarkStore.entries,
                onSelectBookmarkItem: { entry in
                    if let reference = entry.reference {
                        navigateToReference(
                            reference,
                            updateRowView: true,
                            project: false,
                            recordHistory: false
                        )
                        return
                    }
                    ask = entry.title
                    processSearchQuery(updateRowView: true, project: false, recordHistory: false)
                },
                onRemoveBookmarkItem: { entry in
                    guard let reference = entry.reference else { return }
                    bookmarkStore.remove(reference)
                },
                onClearBookmarks: {
                    bookmarkStore.clear()
                },
                historySections: historyStore.groupedSections,
                onSelectHistoryItem: { item in
                    ask = item
                    processSearchQuery(updateRowView: true, project: false, recordHistory: false)
                },
                onClearHistory: {
                    historyStore.clear()
                }
            )
            .focused($focusedColumn, equals: .chapters)
            .navigationSplitViewColumnWidth(min: 150, ideal: 200, max: 280)
        } detail: {
            // Detail: Main content
            MainContentView(
                ask: $ask,
                queryValidationToken: $queryValidationToken,
                windowOpened: $windowOpened,
                searchResults: $searchResults,
                searchQuery: $currentSearchQuery,
                showOnlyPrimary: $showOnlyPrimary,
                focusedColumn: $focusedColumn,
                onSubmit: {
                    processSearchQuery(updateRowView: true, recordHistory: true)
                    focusedColumn = .verses
                },
                closeProjector: closeProjector,
                onSearchVerseSelected: { verse in
                    projectSearchResult(verse: verse)
                },
                onRowVerseProject: { verseNumber in
                    projectVerseFromRow(verseNumber: verseNumber)
                },
                onAddBookmark: { reference in
                    bookmarkStore.add(reference)
                },
                onRemoveBookmark: { reference in
                    bookmarkStore.remove(reference)
                },
                isBookmarked: { reference in
                    bookmarkStore.contains(reference)
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
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            // Only handle Left/Right arrows when text field is NOT focused
            if focusedColumn == .detail {
                // Text field is focused, ignore arrow keys for text editing
                return .ignored
            }

            if press.key == .leftArrow {
                navigateColumnLeft()
                return .handled
            } else if press.key == .rightArrow {
                navigateColumnRight()
                return .handled
            }

            return .ignored
        }
        .sheet(isPresented: $showKeyboardShortcuts) {
            KeyboardShortcutsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleKeyboardShortcuts)) { _ in
            showKeyboardShortcuts.toggle()
        }
        .onChange(of: primaryBibleName) { _, newValue in
            // Recreate primary Bible connection when translation changes
            // Note: Old instance will be deallocated by ARC after ongoing queries complete
            if let newUrl = URL(string: newValue) {
                biblePrimary = Bible(dbUrl: newUrl)

                // Reload current verse with new translation
                if verseRowViewModel.verseRowData.primaryChapter.count > 0 {
                    processSearchQuery(updateRowView: true, project: windowOpened, recordHistory: false)
                }
            }
        }
        .onChange(of: secondaryBibleName) { _, newValue in
            // Recreate secondary Bible connection when translation changes
            // Note: Old instance will be deallocated by ARC after ongoing queries complete
            if let newUrl = URL(string: newValue) {
                bibleSecondary = Bible(dbUrl: newUrl)

                // Reload current verse with new translation
                if verseRowViewModel.verseRowData.primaryChapter.count > 0 {
                    processSearchQuery(updateRowView: true, project: windowOpened, recordHistory: false)
                }
            }
        }
        .onChange(of: showOnlyPrimary) { _, _ in
            guard searchResults != nil || !verseRowViewModel.verseRowData.primaryChapter.isEmpty else { return }
            // Keep primary/secondary boundaries consistent when display mode changes.
            // This prevents stale row counts/text when switching modes.
            processSearchQuery(updateRowView: true, project: windowOpened, recordHistory: false)
        }
        .onChange(of: transparentBackground) { _, _ in
            guard let projectorWindow else {
                return
            }
            applyProjectorWindowAppearance(projectorWindow)
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
        .animation(.easeInOut(duration: 0.3), value: selectedBook)
        .applyWindowSurfaceBackground()
    }
    

    func getChapterCount(bookName: String) {
        guard let chapterRange = VerseBoundary.chapterRange(for: bookName) else {
            selectedBook = nil
            chapterCount = 0
            return
        }
        selectedBook = bookName
        chapterCount = Int32(chapterRange.upperBound)
    }

    func triggerInvalidQueryFeedback() {
        withAnimation(.default) {
            queryValidationToken += 1
        }
    }

    func clearVerseRows() {
        verseRowViewModel.verseRowData = VerseRowData(primaryChapter: [], secondaryChapter: [])
    }

    func appendToHistory(_ title: String) {
        historyStore.append(title)
    }

    func setProjection(
        reference: VerseReference,
        primaryText: String,
        secondaryText: String?,
        owner: ProjectionOwner
    ) {
        projectorViewModel.project(
            ProjectorViewData(
                title: reference.verseQuery.title,
                primaryText: primaryText,
                secondaryText: secondaryText
            ),
            owner: owner
        )
    }

    func startSearchTask(_ operation: @escaping @MainActor (UUID) async -> Void) {
        searchTask?.cancel()
        let searchID = UUID()
        activeSearchID = searchID

        searchTask = Task { [searchID] in
            await operation(searchID)
        }
    }

    func isCurrentSearch(_ searchID: UUID) -> Bool {
        !Task.isCancelled && activeSearchID == searchID
    }

    func processSearchQuery(updateRowView: Bool = true, project: Bool = true, recordHistory: Bool = false) {
        // Check if this is a text search or verse query
        guard let searchType = SearchQuery(ask: ask).searchType() else {
            searchTask?.cancel()
            triggerInvalidQueryFeedback()
            return
        }

        switch searchType {
        case .phrase(let searchText, let filter):
            startSearchTask { searchID in
                await performPhraseSearch(searchText: searchText, filter: filter, searchID: searchID)
            }
        case .multiTerm(let searchText, let filter):
            startSearchTask { searchID in
                await performMultiTermSearch(searchText: searchText, filter: filter, searchID: searchID)
            }
        case .verse(let verseQuery):
            startSearchTask { searchID in
                await performVerseQuery(
                    verseQuery: verseQuery,
                    updateRowView: updateRowView,
                    project: project,
                    searchID: searchID,
                    recordHistory: recordHistory
                )
            }
        }
    }

    func navigateToReference(
        _ reference: VerseReference,
        updateRowView: Bool = true,
        project: Bool = false,
        recordHistory: Bool = false
    ) {
        let verseQuery = reference.verseQuery
        ask = verseQuery.title
        startSearchTask { searchID in
            await performVerseQuery(
                verseQuery: verseQuery,
                updateRowView: updateRowView,
                project: project,
                searchID: searchID,
                recordHistory: recordHistory
            )
        }
    }

    func performPhraseSearch(searchText: String, filter: SearchFilter, searchID: UUID) async {
        let primaryResults: [AVerse]
        let secondaryResults: [AVerse]

        if showOnlyPrimary {
            primaryResults = await biblePrimary.searchTextWithFilterAsync(
                searchQuery: searchText,
                filter: filter
            ) ?? []
            secondaryResults = []
        } else {
            async let primaryResultsTask = biblePrimary.searchTextWithFilterAsync(
                searchQuery: searchText,
                filter: filter
            )
            async let secondaryResultsTask = bibleSecondary.searchTextWithFilterAsync(
                searchQuery: searchText,
                filter: filter
            )

            primaryResults = await primaryResultsTask ?? []
            secondaryResults = await secondaryResultsTask ?? []
        }

        guard isCurrentSearch(searchID) else { return }
        searchResults = (primary: primaryResults, secondary: secondaryResults)
        currentSearchQuery = searchText
        clearVerseRows()
    }

    func performMultiTermSearch(searchText: String, filter: SearchFilter, searchID: UUID) async {
        // Parse as expression-based search (with AND/OR/NOT) using long-lived connections
        let parser = SearchParser(query: searchText)
        if let expression = parser.parse() {
            let primaryResults: [AVerse]
            let secondaryResults: [AVerse]

            if showOnlyPrimary {
                primaryResults = await biblePrimary.searchWithExpressionAsync(
                    expression: expression,
                    filter: filter
                ) ?? []
                secondaryResults = []
            } else {
                async let primaryResultsTask = biblePrimary.searchWithExpressionAsync(
                    expression: expression,
                    filter: filter
                )
                async let secondaryResultsTask = bibleSecondary.searchWithExpressionAsync(
                    expression: expression,
                    filter: filter
                )

                primaryResults = await primaryResultsTask ?? []
                secondaryResults = await secondaryResultsTask ?? []
            }

            guard isCurrentSearch(searchID) else { return }
            searchResults = (primary: primaryResults, secondary: secondaryResults)
            currentSearchQuery = searchText
        } else {
            let primaryResults: [AVerse]
            let secondaryResults: [AVerse]

            if showOnlyPrimary {
                primaryResults = await biblePrimary.searchTextAsync(searchQuery: searchText) ?? []
                secondaryResults = []
            } else {
                async let primaryResultsTask = biblePrimary.searchTextAsync(searchQuery: searchText)
                async let secondaryResultsTask = bibleSecondary.searchTextAsync(searchQuery: searchText)

                primaryResults = await primaryResultsTask ?? []
                secondaryResults = await secondaryResultsTask ?? []
            }

            guard isCurrentSearch(searchID) else { return }
            searchResults = (primary: primaryResults, secondary: secondaryResults)
            currentSearchQuery = searchText
        }

        guard isCurrentSearch(searchID) else { return }
        clearVerseRows()
    }

    func performVerseQuery(
        verseQuery: VerseQuery,
        updateRowView: Bool,
        project: Bool,
        searchID: UUID,
        recordHistory: Bool
    ) async {
        guard isCurrentSearch(searchID) else { return }
        guard let targetReference = VerseReference(verseQuery) else {
            triggerInvalidQueryFeedback()
            return
        }
        let normalizedQuery = targetReference.verseQuery

        // Clear search results when performing verse query
        searchResults = nil
        currentSearchQuery = nil

        getChapterCount(bookName: normalizedQuery.bookName)
        if updateRowView {
            programmaticChapterSelection = normalizedQuery.chapterNumber
        }
        selectedChapter = normalizedQuery.chapterNumber

        let primaryVerse = await biblePrimary.pickAVerseAsync(verseQuery: normalizedQuery)
        let secondaryVerse = !showOnlyPrimary ? await bibleSecondary.pickAVerseAsync(verseQuery: normalizedQuery) : nil
        guard isCurrentSearch(searchID) else { return }

        let primaryText = primaryVerse?.verse
        let secondaryText = secondaryVerse?.verse

        // If neither Bible has the verse, show error
        if primaryText == nil && secondaryText == nil {
            triggerInvalidQueryFeedback()
            return
        }

        let title = normalizedQuery.title
        if recordHistory {
            appendToHistory(title)
        }

        if project {
            let displayPrimaryText = primaryText ?? secondaryText ?? "\u{200c}"
            let displaySecondaryText = primaryText != nil ? secondaryText : nil
            setProjection(
                reference: targetReference,
                primaryText: displayPrimaryText,
                secondaryText: displaySecondaryText,
                owner: .textInputTarget(targetReference)
            )
            openProjector()
        }

        // Row view needs to set/update only when `ask` is via TextField.
        if updateRowView {
            verseTargetModel.verseQuery = normalizedQuery
            ask = title

            let primaryChapter: [AVerse]
            let secondaryChapter: [AVerse]

            if showOnlyPrimary {
                primaryChapter = await biblePrimary.pickAChapterAsync(verseQuery: normalizedQuery) ?? []
                secondaryChapter = []
            } else {
                async let primaryChapterTask = biblePrimary.pickAChapterAsync(verseQuery: normalizedQuery)
                async let secondaryChapterTask = bibleSecondary.pickAChapterAsync(verseQuery: normalizedQuery)

                primaryChapter = await primaryChapterTask ?? []
                secondaryChapter = await secondaryChapterTask ?? []
            }
            guard isCurrentSearch(searchID) else { return }

            verseRowViewModel.verseRowData = VerseRowData(
                primaryChapter: primaryChapter,
                secondaryChapter: secondaryChapter
            )
        }

        guard isCurrentSearch(searchID) else { return }
    }

    private var primaryChapterForDisplay: [AVerse] {
        verseRowViewModel.verseRowData.primaryChapter
    }

    private var secondaryChapterForDisplay: [AVerse] {
        showOnlyPrimary ? [] : verseRowViewModel.verseRowData.secondaryChapter
    }

    private func primaryVerseForNumber(_ verseNumber: Int) -> AVerse? {
        primaryChapterForDisplay.first(where: { $0.verseNumber == verseNumber })
    }

    private func secondaryVerseForNumber(_ verseNumber: Int) -> AVerse? {
        secondaryChapterForDisplay.first(where: { $0.verseNumber == verseNumber })
    }

    func projectVerseFromRow(verseNumber: Int) {
        guard verseNumber > 0 else { return }
        guard let reference = VerseReference(
            book: verseTargetModel.verseQuery.bookName,
            chapter: verseTargetModel.verseQuery.chapterNumber,
            verse: verseNumber
        ) else {
            triggerInvalidQueryFeedback()
            return
        }

        let primaryVerse = primaryVerseForNumber(verseNumber)
        let secondaryVerse = secondaryVerseForNumber(verseNumber)
        guard primaryVerse != nil || secondaryVerse != nil else { return }

        let primaryText = primaryVerse?.verse ?? secondaryVerse?.verse ?? "\u{200c}"
        let secondaryText = primaryVerse != nil ? secondaryVerse?.verse : nil

        verseTargetModel.verseQuery = reference.verseQuery
        ask = reference.verseQuery.title

        setProjection(
            reference: reference,
            primaryText: primaryText,
            secondaryText: secondaryText,
            owner: .verseRowSelection(reference)
        )
        openProjector()
    }

    func projectSearchResult(verse: AVerse) {
        Task { @MainActor in
            guard let reference = VerseReference(
                book: verse.bookName,
                chapter: verse.chapterNumber,
                verse: verse.verseNumber
            ) else {
                triggerInvalidQueryFeedback()
                return
            }
            let verseQuery = reference.verseQuery

            let primaryVerse = await biblePrimary.pickAVerseAsync(verseQuery: verseQuery)
            let secondaryVerse = !showOnlyPrimary ? await bibleSecondary.pickAVerseAsync(verseQuery: verseQuery) : nil

            let primaryText = primaryVerse?.verse ?? verse.verse
            let secondaryText = secondaryVerse?.verse

            setProjection(
                reference: reference,
                primaryText: primaryText,
                secondaryText: secondaryText,
                owner: .searchResult(reference)
            )
            openProjector()
        }
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

    private var projectorWindow: NSWindow? {
        NSApplication.shared.windows.first(where: { $0.title == AppWindowTitle.projector })
    }

    func applyProjectorWindowAppearance(_ window: NSWindow) {
        if transparentBackground {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = .black
        }
    }

    func openProjector() {
        if let existingProjectorWindow = projectorWindow {
            applyProjectorWindowAppearance(existingProjectorWindow)
            let priorKeyWindow = NSApplication.shared.keyWindow
            existingProjectorWindow.orderFrontRegardless()
            if let priorKeyWindow, priorKeyWindow != existingProjectorWindow {
                priorKeyWindow.makeKey()
            }
            windowOpened = true
            return
        }

        // Only create new window if content is valid and no window exists
        if !windowOpened && projectorViewModel.projectorViewData.primaryText != "?" {
            // Set flag immediately to prevent duplicate window creation
            windowOpened = true
            ProjectorView(windowOpened: $windowOpened)
                .environmentObject(projectorViewModel)
                .openNewWindow(with: AppWindowTitle.projector)
            if let projectorWindow {
                applyProjectorWindowAppearance(projectorWindow)
            }
        }
    }

    func closeProjector() {
        // Close window first, then update flag
        if let projectorWindow {
            projectorWindow.close()
        }
        projectorViewModel.clearProjection()
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
            .background(.regularMaterial)

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
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                        .fill(.thinMaterial)
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                        .stroke(.quaternary, lineWidth: 1)
                                                )
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
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                        .fill(.thinMaterial)
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                        .stroke(.quaternary, lineWidth: 1)
                                                )
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
            .background(.regularMaterial)
        }
        .frame(width: 900, height: 600)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
