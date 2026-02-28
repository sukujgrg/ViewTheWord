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
    let showOnlyPrimary: Bool
}

@MainActor
private final class VisibleVerseTracker {

    private var keys: Set<VisibleVerseKey> = []

    func insert(_ key: VisibleVerseKey) {
        keys.insert(key)
    }

    func remove(_ key: VisibleVerseKey) {
        keys.remove(key)
    }

    func removeAll() {
        keys.removeAll()
    }

    func contains(_ key: VisibleVerseKey) -> Bool {
        keys.contains(key)
    }
}

private enum VerseCopySource {
    case primary
    case secondary
    case verseNumber
}

private struct ChapterVerseRow {
    let verseNumber: Int
    let primary: AVerse?
    let secondary: AVerse?
}

struct VerseRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject var verseTargetModel: VerseTargetModel
    @EnvironmentObject var verseRowViewModel: VerseRowViewModel
    @EnvironmentObject var projectorViewModel: ProjectorViewModel

    @AppStorage(AppDefaultsKey.showOnlyPrimary) var showOnlyPrimary = false

    @AppStorage(AppDefaultsKey.primaryBibleName) private var primaryBibleName: String = bundledPrimaryBibleUrl?.absoluteString ?? ""
    @AppStorage(AppDefaultsKey.secondaryBibleName) private var secondaryBibleName: String = bundledSecondaryBibleUrl?.absoluteString ?? ""
    @AppStorage(AppDefaultsKey.verseRowFontSize) private var verseRowFontSize = 17.0

    @State private var currentIndex: Int = -1
    @State private var maxVersesOnCurrentChapter: Int = -1
    @State private var availableBibleUrls: [URL] = []
    @State private var chapterRows: [ChapterVerseRow] = []
    @State private var chapterRowIndexByVerseNumber: [Int: Int] = [:]
    @State private var visibleVerseTracker = VisibleVerseTracker()
    @State private var hoveredRowIndex: Int?
    @State private var hoveredBookmarkActionRowIndex: Int?
    @State private var hoveredCopyActionRowIndex: Int?

    @Binding var windowOpened: Bool
    let onProjectVerse: (Int) -> Void
    let onStopProjection: () -> Void
    let onAddBookmark: (VerseReference) -> Void
    let onRemoveBookmark: (VerseReference) -> Void
    let isBookmarked: (VerseReference) -> Bool

    // MARK: - Computed Properties

    private var isVerseProjected: Bool {
        windowOpened && projectedReference != nil
    }

    private var verseColumnBookHeaderColor: Color {
        colorScheme == .dark
            ? Color.cyan.opacity(0.72)
            : Color.indigo.opacity(0.78)
    }

    private func isCurrentVerse(_ index: Int) -> Bool {
        guard isVerseProjected, let projectedReference, chapterRows.indices.contains(index) else {
            return false
        }

        let verseNumber = chapterRows[index].verseNumber

        return projectedReference.book == verseTargetModel.verseQuery.bookName
            && projectedReference.chapter == verseTargetModel.verseQuery.chapterNumber
            && projectedReference.verse == verseNumber
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
                    .foregroundStyle(verseColumnBookHeaderColor)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else {
            HStack(spacing: 0) {
                translationPicker(selection: $primaryBibleName, title: "Primary translation")
                    .frame(maxWidth: .infinity, alignment: .center)
                Text("\(bookName) \(chapterNumber)")
                    .font(.headline)
                    .foregroundStyle(verseColumnBookHeaderColor)
                    .frame(maxWidth: .infinity, alignment: .center)
                translationPicker(selection: $secondaryBibleName, title: "Secondary translation")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var shouldAnimateVerseSelection: Bool {
        !reduceMotion && displayVerseCount <= 120
    }

    private var shouldAnimateVerseScroll: Bool {
        !reduceMotion && displayVerseCount <= 120
    }

    private var displayVerseCount: Int {
        chapterRows.count
    }

    private var rowCornerRadius: CGFloat { 10 }

    private var rowHorizontalPadding: CGFloat { 10 }

    private var verseTextFontSize: CGFloat {
        CGFloat(verseRowFontSize)
    }

    private var verseNumberFontSize: CGFloat {
        max(11, verseTextFontSize * 0.72)
    }

    private func rowBackgroundColor(index: Int, isActive: Bool, isHovered: Bool) -> Color {
        if isActive {
            return Color.accentColor.opacity(0.11)
        }
        if isHovered {
            return Color.primary.opacity(0.07)
        }
        return index.isMultiple(of: 2) ? Color.primary.opacity(0.03) : Color.clear
    }

    private func rowBorderColor(isActive: Bool) -> Color {
        isActive ? Color.accentColor.opacity(0.38) : Color.primary.opacity(0.10)
    }

    private var headerVerse: AVerse? {
        verseRowViewModel.verseRowData.primaryChapter.first
            ?? verseRowViewModel.verseRowData.secondaryChapter.first
    }

    private func indexForVerseNumber(_ verseNumber: Int) -> Int? {
        chapterRowIndexByVerseNumber[verseNumber]
    }

    private var clampedCurrentIndex: Int {
        guard !chapterRows.isEmpty else { return -1 }

        if let exactIndex = indexForVerseNumber(verseTargetModel.verseQuery.verseNumber) {
            return exactIndex
        }

        let targetVerseNumber = verseTargetModel.verseQuery.verseNumber
        if let precedingIndex = chapterRows.lastIndex(where: { $0.verseNumber < targetVerseNumber }) {
            return precedingIndex
        }

        return 0
    }

    private func rebuildChapterRows() {
        var primaryVersesByNumber: [Int: AVerse] = [:]
        primaryVersesByNumber.reserveCapacity(verseRowViewModel.verseRowData.primaryChapter.count)
        for verse in verseRowViewModel.verseRowData.primaryChapter {
            primaryVersesByNumber[verse.verseNumber] = verse
        }

        var secondaryVersesByNumber: [Int: AVerse] = [:]
        secondaryVersesByNumber.reserveCapacity(verseRowViewModel.verseRowData.secondaryChapter.count)
        for verse in verseRowViewModel.verseRowData.secondaryChapter {
            secondaryVersesByNumber[verse.verseNumber] = verse
        }

        let verseNumbers: [Int]
        if showOnlyPrimary {
            verseNumbers = primaryVersesByNumber.keys.sorted()
        } else {
            verseNumbers = Set(primaryVersesByNumber.keys)
                .union(secondaryVersesByNumber.keys)
                .sorted()
        }

        var rebuiltRows: [ChapterVerseRow] = []
        rebuiltRows.reserveCapacity(verseNumbers.count)

        var rebuiltIndexByVerseNumber: [Int: Int] = [:]
        rebuiltIndexByVerseNumber.reserveCapacity(verseNumbers.count)

        for (index, verseNumber) in verseNumbers.enumerated() {
            rebuiltRows.append(
                ChapterVerseRow(
                    verseNumber: verseNumber,
                    primary: primaryVersesByNumber[verseNumber],
                    secondary: showOnlyPrimary ? nil : secondaryVersesByNumber[verseNumber]
                )
            )
            rebuiltIndexByVerseNumber[verseNumber] = index
        }

        chapterRows = rebuiltRows
        chapterRowIndexByVerseNumber = rebuiltIndexByVerseNumber
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 4) {
            if let headerVerse {
                headerView(bookName: headerVerse.bookName, chapterNumber: headerVerse.chapterNumber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.regularMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.quaternary, lineWidth: 1)
                    )
                    .padding(.horizontal, 8)
                    .zIndex(1)
            }

            ScrollViewReader { value in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(chapterRows.enumerated()), id: \.element.verseNumber) { index, row in
                            verseRow(index: index, row: row, isActive: isCurrentVerse(index))
                                .id(index)
                                .onAppear {
                                    visibleVerseTracker.insert(currentVisibleKey(index: index))
                                }
                                .onDisappear {
                                    visibleVerseTracker.remove(currentVisibleKey(index: index))
                                }
                        }
                    }
                    .padding(.horizontal, rowHorizontalPadding)
                    .padding(.vertical, 2)
                    .id(showOnlyPrimary)
                }
                .contentShape(Rectangle())
                .onAppear {
                    // First load path: ensure initial query selection gets the same
                    // scroll behavior as subsequent query changes.
                    rebuildChapterRows()
                    hoveredRowIndex = nil
                    visibleVerseTracker.removeAll()
                    updateSelectionAndScroll(proxy: value)
                }
                .onTapGesture {
                    // Make sure the view can receive keyboard events
                }
                .onChange(of: verseRowViewModel.verseRowData.id) { _, _ in
                    rebuildChapterRows()
                    hoveredRowIndex = nil
                    visibleVerseTracker.removeAll()
                    updateSelectionAndScroll(proxy: value)
                }
                .onChange(of: verseTargetModel.verseQuery.title) { _, _ in
                    currentIndex = clampedCurrentIndex
                    scrollToCurrentVerse(proxy: value)
                }
                // this scroll is needed when switching between books/chapters
                .onChange(of: verseTargetModel.verseQuery.bookAndChapter) { _, _ in
                    visibleVerseTracker.removeAll()
                    updateSelectionAndScroll(proxy: value)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            // Initialize on first appearance
            rebuildChapterRows()
            maxVersesOnCurrentChapter = displayVerseCount
            currentIndex = clampedCurrentIndex
            hoveredRowIndex = nil
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
    private func verseRow(index: Int, row: ChapterVerseRow, isActive: Bool) -> some View {
        let isHovered = hoveredRowIndex == index
        let showsQuickActions = isHovered || isActive
        let contextCopySource: VerseCopySource = showOnlyPrimary ? .primary : .verseNumber

        HStack(alignment: .top, spacing: 12) {
            verseNumberGutter(verseNumber: row.verseNumber, isActive: isActive)

            verseTextContent(text: row.primary?.verse ?? "\u{200c}")

            if !showOnlyPrimary {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 1)
                    .padding(.vertical, 2)

                verseTextContent(text: row.secondary?.verse ?? "\u{200c}")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .fill(rowBackgroundColor(index: index, isActive: isActive, isHovered: isHovered))
        )
        .overlay(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .stroke(rowBorderColor(isActive: isActive), lineWidth: isActive ? 1.2 : 1)
        )
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.leading, 4)
                .padding(.vertical, 6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            rowQuickActions(index: index, isVisible: showsQuickActions)
        }
        .contentShape(RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous))
        .onTapGesture {
            requestProjection(at: index)
        }
        .contextMenu {
            verseContextMenuItems(for: index, source: contextCopySource)
        }
        .onHover { isHovering in
            if isHovering {
                hoveredRowIndex = index
            } else if hoveredRowIndex == index {
                hoveredRowIndex = nil
            }
        }
        .animation(
            shouldAnimateVerseSelection ? .easeInOut(duration: 0.14) : nil,
            value: isActive
        )
        .accessibilityLabel("Verse \(row.verseNumber)")
        .accessibilityHint("Click to project this verse to the projector window")
    }

    @ViewBuilder
    private func verseNumberGutter(verseNumber: Int, isActive: Bool) -> some View {
        Text(String(verseNumber))
            .font(.system(size: verseNumberFontSize, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .frame(width: 36, alignment: .trailing)
            .padding(.top, 2)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func verseTextContent(text: String) -> some View {
        Text(text)
            .font(.system(size: verseTextFontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowQuickActions(index: Int, isVisible: Bool) -> some View {
        let copySource: VerseCopySource = showOnlyPrimary ? .primary : .verseNumber
        let bookmarkHovered = hoveredBookmarkActionRowIndex == index
        let copyHovered = hoveredCopyActionRowIndex == index

        HStack(spacing: 6) {
            if let reference = referenceForIndex(index) {
                Button {
                    if isBookmarked(reference) {
                        onRemoveBookmark(reference)
                    } else {
                        onAddBookmark(reference)
                    }
                } label: {
                    Image(systemName: isBookmarked(reference) ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(isBookmarked(reference) ? Color.accentColor : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(
                                    bookmarkHovered
                                        ? Color(nsColor: .controlBackgroundColor)
                                        : Color.primary.opacity(0.08)
                                )
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    bookmarkHovered
                                        ? Color.primary.opacity(0.24)
                                        : Color.primary.opacity(0.10),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(isBookmarked(reference) ? "Remove bookmark" : "Add bookmark")
                .onHover { isHovering in
                    if isHovering {
                        hoveredBookmarkActionRowIndex = index
                    } else if hoveredBookmarkActionRowIndex == index {
                        hoveredBookmarkActionRowIndex = nil
                    }
                }
            }

            Menu {
                copyMenuItems(for: index, source: copySource)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(
                                copyHovered
                                    ? Color(nsColor: .controlBackgroundColor)
                                    : Color.primary.opacity(0.08)
                            )
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                copyHovered
                                    ? Color.primary.opacity(0.24)
                                    : Color.primary.opacity(0.10),
                                lineWidth: 1
                            )
                    )
            }
            .menuStyle(.borderlessButton)
            .disabled(!hasCopyMenuItems(for: index, source: copySource))
            .help("Copy verse")
            .onHover { isHovering in
                if isHovering {
                    hoveredCopyActionRowIndex = index
                } else if hoveredCopyActionRowIndex == index {
                    hoveredCopyActionRowIndex = nil
                }
            }
        }
        .padding(.trailing, 6)
        .padding(.bottom, 6)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
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
        guard chapterRows.indices.contains(index) else {
            return
        }
        let verseNumber = chapterRows[index].verseNumber

        Task { @MainActor in
            await Task.yield()
            onProjectVerse(verseNumber)
        }
    }

    private func updateSelectionAndScroll(proxy: ScrollViewProxy) {
        maxVersesOnCurrentChapter = displayVerseCount
        currentIndex = clampedCurrentIndex
        scrollToCurrentVerse(proxy: proxy)
    }

    private func scrollToCurrentVerse(proxy: ScrollViewProxy) {
        guard currentIndex >= 0, currentIndex < displayVerseCount else { return }
        Task { @MainActor in
            let targetKey = currentVisibleKey(index: currentIndex)
            await Task.yield()
            await Task.yield()
            if visibleVerseTracker.contains(targetKey) {
                return
            }
            if !shouldAnimateVerseScroll {
                proxy.scrollTo(currentIndex, anchor: .center)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
            // Lazy stacks can settle in two phases for distant targets.
            await Task.yield()
            await Task.yield()
            if !visibleVerseTracker.contains(targetKey) {
                proxy.scrollTo(currentIndex, anchor: .center)
            }
        }
    }

    private func currentVisibleKey(index: Int) -> VisibleVerseKey {
        VisibleVerseKey(
            dataID: verseRowViewModel.verseRowData.id,
            index: index,
            showOnlyPrimary: showOnlyPrimary
        )
    }

    private func referenceForIndex(_ index: Int) -> VerseReference? {
        guard chapterRows.indices.contains(index) else {
            return nil
        }
        let verseNumber = chapterRows[index].verseNumber
        return VerseReference(
            book: verseTargetModel.verseQuery.bookName,
            chapter: verseTargetModel.verseQuery.chapterNumber,
            verse: verseNumber
        )
    }

    private func primaryVerseForIndex(_ index: Int) -> AVerse? {
        guard chapterRows.indices.contains(index) else {
            return nil
        }
        return chapterRows[index].primary
    }

    private func secondaryVerseForIndex(_ index: Int) -> AVerse? {
        guard chapterRows.indices.contains(index) else {
            return nil
        }
        return chapterRows[index].secondary
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
