import SwiftUI
import AppKit

class VerseRowViewModel: ObservableObject {
    @Published var verseRowData: VerseRowData = .init(primaryChapter: [], secondaryChapter: [])
}

struct VerseRowData: Identifiable {
    let id: UUID = .init()
    let primaryChapter: [AVerse]
    let secondaryChapter: [AVerse]
}

private struct VisibleVerseKey: Hashable {
    let dataID: UUID
    let index: Int
}

private enum VerseCopySource {
    case primary
    case secondary
    case verseNumber
}

struct VerseRowView: View {
    @EnvironmentObject var verseTargetModel: VerseTargetModel
    @EnvironmentObject var verseRowViewModel: VerseRowViewModel
    @EnvironmentObject var projectorViewModel: ProjectorViewModel

    @AppStorage(AppDefaultsKey.showOnlyPrimary) var showOnlyPrimary = false

    @AppStorage(AppDefaultsKey.primaryBibleName) private var primaryBibleName: String = bundledPrimaryBibleUrl?.absoluteString ?? ""
    @AppStorage(AppDefaultsKey.secondaryBibleName) private var secondaryBibleName: String = bundledSecondaryBibleUrl?.absoluteString ?? ""

    @State private var currentIndex: Int = -1
    @State private var maxVersesOnCurrentChapter: Int = -1
    @State private var availableBibleUrls: [URL] = []
    @State private var visibleVerseKeys: Set<VisibleVerseKey> = []

    @Binding var windowOpened: Bool
    let onProjectVerse: (Int) -> Void
    let onStopProjection: () -> Void
    let onAddBookmark: (VerseReference) -> Void
    let onRemoveBookmark: (VerseReference) -> Void
    let isBookmarked: (VerseReference) -> Bool

    // MARK: - Computed Properties

    private var columns: [GridItem] {
        if showOnlyPrimary {
            return [
                GridItem(.flexible())
            ]
        } else {
            return [
                GridItem(.flexible()),
                GridItem(.fixed(60)),
                GridItem(.flexible())
            ]
        }
    }

    private var isVerseProjected: Bool {
        windowOpened && projectedReference != nil
    }

    private func isCurrentVerse(_ index: Int) -> Bool {
        guard isVerseProjected, let projectedReference else {
            return false
        }

        return projectedReference.book == verseTargetModel.verseQuery.bookName
            && projectedReference.chapter == verseTargetModel.verseQuery.chapterNumber
            && projectedReference.verse == index + 1
    }

    private var projectedReference: VerseReference? {
        switch projectorViewModel.projectionOwner {
        case .textInputTarget(let reference),
             .verseRowSelection(let reference),
             .searchResult(let reference):
            return reference
        case .none:
            return nil
        }
    }

    private func formatBibleName(_ bibleUrl: String) -> String {
        let fileName = URL(string: bibleUrl)?.lastPathComponent ?? bibleUrl
        return fileName
            .removingPercentEncoding?
            .replacingOccurrences(of: ".bible", with: "")
            .replacingOccurrences(of: "_", with: " ") ?? fileName
    }

    private func translationLabel(for url: URL) -> String {
        formatBibleName(url.absoluteString)
    }

    private func refreshAvailableBibles() {
        availableBibleUrls = BibleUrl().getAvailableBibleUrls()
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    @ViewBuilder
    private func translationPicker(
        selection: Binding<String>,
        title: String
    ) -> some View {
        Picker(title, selection: selection) {
            if !availableBibleUrls.contains(where: { $0.absoluteString == selection.wrappedValue }) {
                Text(formatBibleName(selection.wrappedValue))
                    .tag(selection.wrappedValue)
            }
            ForEach(availableBibleUrls, id: \.absoluteString) { url in
                Text(translationLabel(for: url))
                    .tag(url.absoluteString)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func headerView(bookName: String, chapterNumber: Int) -> some View {
        if showOnlyPrimary {
            HStack(spacing: 12) {
                translationPicker(selection: $primaryBibleName, title: "Primary translation")
                    .frame(width: 220)
                Text("\(bookName) \(chapterNumber)")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            HStack(spacing: 0) {
                translationPicker(selection: $primaryBibleName, title: "Primary translation")
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("\(bookName) \(chapterNumber)")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                translationPicker(selection: $secondaryBibleName, title: "Secondary translation")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var verseCount: Int {
        max(verseRowViewModel.verseRowData.primaryChapter.count, verseRowViewModel.verseRowData.secondaryChapter.count)
    }

    private var clampedCurrentIndex: Int {
        guard verseCount > 0 else { return -1 }
        return min(max(verseTargetModel.verseQuery.verseNumber - 1, 0), verseCount - 1)
    }

    // MARK: - Body

    var body: some View {
        if !verseRowViewModel.verseRowData.primaryChapter.isEmpty {
            let primaryChapter = verseRowViewModel.verseRowData.primaryChapter

            // Header with Bible names and chapter reference
            VStack(spacing: 0) {
                Divider()
                headerView(bookName: primaryChapter[0].bookName, chapterNumber: primaryChapter[0].chapterNumber)
                    .padding(.vertical, 6)
                Divider()
            }
        }
        ScrollViewReader { value in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    let count = verseCount
                    ForEach(0 ..< count, id: \.self) { index in
                        if showOnlyPrimary {
                            // Show only primary mode: Verse with superscript number
                            verseCellWithSuperscript(
                                text: verseRowViewModel.verseRowData.primaryChapter.indices.contains(index)
                                    ? verseRowViewModel.verseRowData.primaryChapter[index].verse
                                    : "\u{200c}",
                                index: index,
                                isActive: isCurrentVerse(index)
                            )
                            .id(index)
                            .onAppear {
                                visibleVerseKeys.insert(currentVisibleKey(index: index))
                            }
                            .onDisappear {
                                visibleVerseKeys.remove(currentVisibleKey(index: index))
                            }
                        } else {
                            // Full mode: Primary verse, verse number, secondary verse
                            verseCell(
                                text: verseRowViewModel.verseRowData.primaryChapter.indices.contains(index)
                                    ? verseRowViewModel.verseRowData.primaryChapter[index].verse
                                    : "\u{200c}",
                                index: index,
                                isActive: isCurrentVerse(index),
                                copySource: .primary
                            )
                            .id(index)
                            .onAppear {
                                visibleVerseKeys.insert(currentVisibleKey(index: index))
                            }
                            .onDisappear {
                                visibleVerseKeys.remove(currentVisibleKey(index: index))
                            }
                            verseNumberButton(index: index, isActive: isCurrentVerse(index))
                            verseCell(
                                text: verseRowViewModel.verseRowData.secondaryChapter.indices.contains(index)
                                    ? verseRowViewModel.verseRowData.secondaryChapter[index].verse
                                    : "\u{200c}",
                                index: index,
                                isActive: isCurrentVerse(index),
                                copySource: .secondary
                            )
                        }
                    }
                    .onChange(of: verseRowViewModel.verseRowData.id) { _, _ in
                        visibleVerseKeys.removeAll()
                        updateSelectionAndScroll(proxy: value)
                    }
                    .onChange(of: verseTargetModel.verseQuery.title) { _, _ in
                        currentIndex = clampedCurrentIndex
                        scrollToCurrentVerse(proxy: value)
                    }
                    // this scroll is needed when switching between books/chapters
                    .onChange(of: verseTargetModel.verseQuery.bookAndChapter) { _, _ in
                        visibleVerseKeys.removeAll()
                        updateSelectionAndScroll(proxy: value)
                    }
                }
            }
            .padding(.horizontal)
            .contentShape(Rectangle())
            .onAppear {
                // First load path: ensure initial query selection gets the same
                // scroll behavior as subsequent query changes.
                visibleVerseKeys.removeAll()
                updateSelectionAndScroll(proxy: value)
            }
            .onTapGesture {
                // Make sure the view can receive keyboard events
            }
        }
        .frame(maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            // Initialize on first appearance
            maxVersesOnCurrentChapter = verseCount
            currentIndex = clampedCurrentIndex
            refreshAvailableBibles()
        }
        .onChange(of: primaryBibleName) { _, _ in
            refreshAvailableBibles()
        }
        .onChange(of: secondaryBibleName) { _, _ in
            refreshAvailableBibles()
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { keyPress in
            let modifiers = keyPress.modifiers

            if keyPress.key == .downArrow {
                if modifiers.contains(.command) {
                    navigateVerses(offset: 5)
                } else if modifiers.contains(.option) {
                    navigateToNextChapter()
                } else {
                    navigateVerses(offset: 1)
                }
                return .handled
            }

            if keyPress.key == .upArrow {
                if modifiers.contains(.command) {
                    navigateVerses(offset: -5)
                } else if modifiers.contains(.option) {
                    navigateToPreviousChapter()
                } else {
                    navigateVerses(offset: -1)
                }
                return .handled
            }

            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: " ")) { _ in
            if currentIndex >= 0 {
                toggleProjector(at: currentIndex)
            }
            return .handled
        }
        .onKeyPress { keyPress in
            // Handle special function keys that don't have KeyEquivalent
            // Check by characters for Page Up/Down, Home/End
            if keyPress.characters == "\u{F72C}" { // Page Up
                navigateVerses(offset: -10)
                return .handled
            }

            if keyPress.characters == "\u{F72D}" { // Page Down
                navigateVerses(offset: 10)
                return .handled
            }

            if keyPress.characters == "\u{F729}" { // Home
                navigateToVerse(0)
                return .handled
            }

            if keyPress.characters == "\u{F72B}" { // End
                navigateToVerse(maxVersesOnCurrentChapter - 1)
                return .handled
            }

            return .ignored
        }
    }

    // MARK: - View Components

    @ViewBuilder
    private func verseCell(text: String, index: Int, isActive: Bool, copySource: VerseCopySource) -> some View {
        Text(text)
            .onTapGesture { requestProjection(at: index) }
            .contextMenu {
                verseContextMenuItems(for: index, source: copySource)
            }
            .padding()
            .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
    }

    @ViewBuilder
    private func verseCellWithSuperscript(text: String, index: Int, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(String(index + 1))
                .font(.system(size: 12))
                .baselineOffset(8)
                .foregroundColor(.secondary)

            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onTapGesture { requestProjection(at: index) }
        .contextMenu {
            verseContextMenuItems(for: index, source: .primary)
        }
        .padding()
        .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        .accessibilityLabel("Verse \(index + 1): \(text)")
        .accessibilityHint("Tap to project this verse to the projector window")
    }

    @ViewBuilder
    private func verseNumberButton(index: Int, isActive: Bool) -> some View {
        Button(action: { requestProjection(at: index) }) {
            Text(String(index + 1))
                .frame(width: 60, height: 60)
                .background(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
                .foregroundColor(.white)
        }
        .contextMenu {
            verseContextMenuItems(for: index, source: .verseNumber)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Verse \(index + 1)")
        .accessibilityHint("Project this verse to the projector window")
    }

    // MARK: - Navigation Helpers

    private func navigateVerses(offset: Int) {
        let newIndex = currentIndex + offset
        if newIndex >= 0 && newIndex < maxVersesOnCurrentChapter {
            requestProjection(at: newIndex)
        }
    }

    private func navigateToVerse(_ index: Int) {
        if index >= 0 && index < maxVersesOnCurrentChapter {
            requestProjection(at: index)
        }
    }

    private func navigateToNextChapter() {
        guard let currentReference = VerseReference(verseTargetModel.verseQuery) else {
            return
        }
        let nextChapter = currentReference.chapter + 1
        guard VerseBoundary.isValidChapter(nextChapter, in: currentReference.book) else {
            return
        }

        let newQuery = VerseQuery(
            bookName: currentReference.book,
            chapterNumber: nextChapter,
            verseNumber: 1
        )
        verseTargetModel.verseQuery = newQuery
    }

    private func navigateToPreviousChapter() {
        guard let currentReference = VerseReference(verseTargetModel.verseQuery) else {
            return
        }
        let prevChapter = currentReference.chapter - 1
        guard VerseBoundary.isValidChapter(prevChapter, in: currentReference.book) else {
            return
        }

        let newQuery = VerseQuery(
            bookName: currentReference.book,
            chapterNumber: prevChapter,
            verseNumber: 1
        )
        verseTargetModel.verseQuery = newQuery
    }

    private func toggleProjector(at index: Int) {
        if isCurrentVerse(index) {
            onStopProjection()
        } else {
            requestProjection(at: index)
        }
    }

    private func requestProjection(at index: Int) {
        Task { @MainActor in
            await Task.yield()
            onProjectVerse(index)
        }
    }

    private func updateSelectionAndScroll(proxy: ScrollViewProxy) {
        maxVersesOnCurrentChapter = verseCount
        currentIndex = clampedCurrentIndex
        scrollToCurrentVerse(proxy: proxy)
    }

    private func scrollToCurrentVerse(proxy: ScrollViewProxy) {
        guard currentIndex >= 0, currentIndex < verseCount else { return }
        Task { @MainActor in
            let targetKey = currentVisibleKey(index: currentIndex)
            await Task.yield()
            await Task.yield()
            if visibleVerseKeys.contains(targetKey) {
                return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(currentIndex, anchor: .center)
            }
            // Lazy grids can settle in two phases for distant targets.
            await Task.yield()
            await Task.yield()
            if !visibleVerseKeys.contains(targetKey) {
                proxy.scrollTo(currentIndex, anchor: .center)
            }
        }
    }

    private func currentVisibleKey(index: Int) -> VisibleVerseKey {
        VisibleVerseKey(dataID: verseRowViewModel.verseRowData.id, index: index)
    }

    private func referenceForIndex(_ index: Int) -> VerseReference? {
        guard index >= 0, index < verseCount else {
            return nil
        }
        return VerseReference(
            book: verseTargetModel.verseQuery.bookName,
            chapter: verseTargetModel.verseQuery.chapterNumber,
            verse: index + 1
        )
    }

    private func primaryVerseForIndex(_ index: Int) -> AVerse? {
        guard verseRowViewModel.verseRowData.primaryChapter.indices.contains(index) else {
            return nil
        }
        return verseRowViewModel.verseRowData.primaryChapter[index]
    }

    private func secondaryVerseForIndex(_ index: Int) -> AVerse? {
        guard verseRowViewModel.verseRowData.secondaryChapter.indices.contains(index) else {
            return nil
        }
        return verseRowViewModel.verseRowData.secondaryChapter[index]
    }

    private func copyVerseToPasteboard(_ verse: AVerse, translationName: String) {
        let output = "\(verse.bookName) \(verse.chapterNumber):\(verse.verseNumber) \(verse.verse) (\(translationName))"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    @ViewBuilder
    private func copyMenuItems(for index: Int, source: VerseCopySource) -> some View {
        switch source {
        case .primary:
            if let verse = primaryVerseForIndex(index) {
                Button("Copy Verse") {
                    copyVerseToPasteboard(verse, translationName: formatBibleName(primaryBibleName))
                }
            }
        case .secondary:
            if let verse = secondaryVerseForIndex(index) {
                Button("Copy Verse") {
                    copyVerseToPasteboard(verse, translationName: formatBibleName(secondaryBibleName))
                }
            }
        case .verseNumber:
            if let verse = primaryVerseForIndex(index) {
                Button("Copy Verse (Primary)") {
                    copyVerseToPasteboard(verse, translationName: formatBibleName(primaryBibleName))
                }
            }
            if let verse = secondaryVerseForIndex(index) {
                Button("Copy Verse (Secondary)") {
                    copyVerseToPasteboard(verse, translationName: formatBibleName(secondaryBibleName))
                }
            }
        }
    }

    private func hasCopyMenuItems(for index: Int, source: VerseCopySource) -> Bool {
        switch source {
        case .primary:
            return primaryVerseForIndex(index) != nil
        case .secondary:
            return secondaryVerseForIndex(index) != nil
        case .verseNumber:
            return primaryVerseForIndex(index) != nil || secondaryVerseForIndex(index) != nil
        }
    }

    @ViewBuilder
    private func verseContextMenuItems(for index: Int, source: VerseCopySource) -> some View {
        copyMenuItems(for: index, source: source)
        if hasCopyMenuItems(for: index, source: source) {
            Divider()
        }
        bookmarkMenuItems(for: index)
    }

    @ViewBuilder
    private func bookmarkMenuItems(for index: Int) -> some View {
        if let reference = referenceForIndex(index) {
            if isBookmarked(reference) {
                Button("Remove Bookmark") {
                    onRemoveBookmark(reference)
                }
            } else {
                Button("Add Bookmark") {
                    onAddBookmark(reference)
                }
            }
        }
    }
}
