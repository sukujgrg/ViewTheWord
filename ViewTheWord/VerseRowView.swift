import SwiftUI

class VerseRowViewModel: ObservableObject {
    @Published var verseRowData: VerseRowData = .init(primaryChapter: [], secondaryChapter: [])
}

struct VerseRowData: Identifiable {
    let id: UUID = .init()
    let primaryChapter: [AVerse]
    let secondaryChapter: [AVerse]
}

struct VerseRowView: View {
    @EnvironmentObject var verseTargetModel: VerseTargetModel
    @EnvironmentObject var verseRowViewModel: VerseRowViewModel
    @EnvironmentObject var projectorViewModel: ProjectorViewModel

    @AppStorage("showOnlyPrimary") var showOnlyPrimary = false
    @AppStorage("scrollTo") var scrollTo = true

    @AppStorage("PrimaryBibleName") private var primaryBibleName: String = bundledPrimaryBibleUrl?.absoluteString ?? ""
    @AppStorage("SecondaryBibleName") private var secondaryBibleName: String = bundledSecondaryBibleUrl?.absoluteString ?? ""

    @State private var currentIndex: Int = -1
    @State private var maxVersesOnCurrentChapter: Int = -1

    @Binding var windowOpened: Bool

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
        projectorViewModel.projectorViewData.title == verseTargetModel.verseQuery.title && windowOpened
    }

    private func isCurrentVerse(_ index: Int) -> Bool {
        isVerseProjected && currentIndex == index
    }

    private func formatBibleName(_ bibleUrl: String) -> String {
        bibleUrl.components(separatedBy: "/")
            .last?
            .replacingOccurrences(of: ".bible", with: "")
            .replacingOccurrences(of: "_", with: " ") ?? ""
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
            Grid {
                Divider()
                GridRow {
                    Text(formatBibleName(primaryBibleName))
                        .bold()
                    Text("\(primaryChapter[0].bookName) \(primaryChapter[0].chapterNumber)")
                    if !showOnlyPrimary {
                        Text(formatBibleName(secondaryBibleName))
                            .bold()
                    }
                }
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
                        } else {
                            // Full mode: Primary verse, verse number, secondary verse
                            verseCell(
                                text: verseRowViewModel.verseRowData.primaryChapter.indices.contains(index)
                                    ? verseRowViewModel.verseRowData.primaryChapter[index].verse
                                    : "\u{200c}",
                                index: index,
                                isActive: isCurrentVerse(index)
                            )
                            verseNumberButton(index: index, isActive: isCurrentVerse(index))
                            verseCell(
                                text: verseRowViewModel.verseRowData.secondaryChapter.indices.contains(index)
                                    ? verseRowViewModel.verseRowData.secondaryChapter[index].verse
                                    : "\u{200c}",
                                index: index,
                                isActive: isCurrentVerse(index)
                            )
                        }
                    }
                    .onChange(of: verseRowViewModel.verseRowData.id) { _, _ in
                        updateSelectionAndScroll(proxy: value)
                    }
                    .onChange(of: verseTargetModel.verseQuery.title) { _, _ in
                        currentIndex = clampedCurrentIndex
                        scrollToCurrentVerse(proxy: value)
                    }
                    // this scroll is needed when switching between books/chapters
                    .onChange(of: verseTargetModel.verseQuery.bookAndChapter) { _, _ in
                        updateSelectionAndScroll(proxy: value)
                    }
                }
            }
            .padding(.horizontal)
            .contentShape(Rectangle())
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
    private func verseCell(text: String, index: Int, isActive: Bool) -> some View {
        Text(text)
            .onTapGesture { projectVerse(at: index) }
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
        .onTapGesture { projectVerse(at: index) }
        .padding()
        .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        .accessibilityLabel("Verse \(index + 1): \(text)")
        .accessibilityHint("Tap to project this verse to the projector window")
    }

    @ViewBuilder
    private func verseNumberButton(index: Int, isActive: Bool) -> some View {
        Button(action: { projectVerse(at: index) }) {
            Text(String(index + 1))
                .frame(width: 60, height: 60)
                .background(isActive ? Color.accentColor : Color.secondary.opacity(0.5))
                .foregroundColor(.white)
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Verse \(index + 1)")
        .accessibilityHint("Project this verse to the projector window")
    }

    // MARK: - Navigation Helpers

    private func navigateVerses(offset: Int) {
        let newIndex = currentIndex + offset
        if newIndex >= 0 && newIndex < maxVersesOnCurrentChapter {
            projectVerse(at: newIndex)
        }
    }

    private func navigateToVerse(_ index: Int) {
        if index >= 0 && index < maxVersesOnCurrentChapter {
            projectVerse(at: index)
        }
    }

    private func navigateToNextChapter() {
        let nextChapter = verseTargetModel.verseQuery.chapterNumber + 1
        guard let maxChapter = bibleBooks[verseTargetModel.verseQuery.bookName]?.last,
              nextChapter <= maxChapter else {
            return
        }

        let newQuery = VerseQuery(
            bookName: verseTargetModel.verseQuery.bookName,
            chapterNumber: nextChapter,
            verseNumber: 1
        )
        verseTargetModel.verseQuery = newQuery
    }

    private func navigateToPreviousChapter() {
        let prevChapter = verseTargetModel.verseQuery.chapterNumber - 1
        guard prevChapter >= 1 else {
            return
        }

        let newQuery = VerseQuery(
            bookName: verseTargetModel.verseQuery.bookName,
            chapterNumber: prevChapter,
            verseNumber: 1
        )
        verseTargetModel.verseQuery = newQuery
    }

    private func toggleProjector(at index: Int) {
        if windowOpened && currentIndex == index {
            // Close projector if showing same verse
            NSApplication.shared.windows.first(where: { $0.title == AppWindowTitle.projector })?.close()
        } else {
            // Project the verse
            projectVerse(at: index)
        }
    }

    private func updateVerseTarget(at index: Int) {
        verseTargetModel.verseQuery = VerseQuery(
            bookName: verseTargetModel.verseQuery.bookName,
            chapterNumber: verseTargetModel.verseQuery.chapterNumber,
            verseNumber: index + 1
        )
    }

    private func projectVerse(at index: Int) {
        updateVerseTarget(at: index)
        let title = verseTargetModel.verseQuery.title

        var primaryText: String?
        if index < verseRowViewModel.verseRowData.primaryChapter.count {
            primaryText = verseRowViewModel.verseRowData.primaryChapter[index].verse
        }

        var secondaryText: String?
        if !showOnlyPrimary {
            if index < verseRowViewModel.verseRowData.secondaryChapter.count {
                secondaryText = verseRowViewModel.verseRowData.secondaryChapter[index].verse
            }
        }

        projectorViewModel.projectorViewData = ProjectorViewData(
            title: title, primaryText: primaryText ?? "\u{200c}", secondaryText: secondaryText ?? "\u{200c}"
        )

        // Check if projector window already exists
        if NSApplication.shared.windows.contains(where: { $0.title == AppWindowTitle.projector }) {
            // Window exists, just update flag
            windowOpened = true
            return
        }

        // Create new window only if it doesn't exist
        if !windowOpened {
            windowOpened = true
            ProjectorView(windowOpened: $windowOpened)
                .environmentObject(projectorViewModel)
                .openNewWindow(with: AppWindowTitle.projector)
        }
    }

    private func updateSelectionAndScroll(proxy: ScrollViewProxy) {
        maxVersesOnCurrentChapter = verseCount
        currentIndex = clampedCurrentIndex
        scrollToCurrentVerse(proxy: proxy)
    }

    private func scrollToCurrentVerse(proxy: ScrollViewProxy) {
        guard scrollTo, currentIndex >= 0, currentIndex < verseCount else { return }
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(currentIndex, anchor: .center)
            }
        }
    }
}
