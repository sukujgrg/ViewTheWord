import AppKit
import XCTest
@testable import ViewTheWordCore

private struct WorkspaceBible: BibleReading {
    func chapter(_ reference: VerseReference) async throws -> [AVerse] {
        (1...5).map { AVerse(reference: VerseReference(book: reference.book, chapter: reference.chapter, verse: $0)!, verse: "Verse \($0) about hope and faith.") }
    }
    func verses(_ references: [VerseReference]) async throws -> [AVerse] {
        references.map { AVerse(reference: $0, verse: "Hope and faith.") }
    }
    func search(_ request: TextSearchRequest, after: VerseCoordinate?, limit: Int) async throws -> [AVerse] {
        try await chapter(VerseReference(book: "John", chapter: 3, verse: 1)!)
    }
}

private actor WorkspaceReadAudit: BibleReading {
    private(set) var reads = 0
    var failsSearch = true
    func allowSearch() { failsSearch = false }
    func chapter(_ reference: VerseReference) async throws -> [AVerse] {
        reads += 1
        return try await WorkspaceBible().chapter(reference)
    }
    func verses(_ references: [VerseReference]) async throws -> [AVerse] {
        reads += 1
        return try await WorkspaceBible().verses(references)
    }
    func search(_ request: TextSearchRequest, after: VerseCoordinate?, limit: Int) async throws -> [AVerse] {
        reads += 1
        if failsSearch { throw BibleError.database("Search failed") }
        return try await WorkspaceBible().search(request, after: after, limit: limit)
    }
}

@MainActor
final class NativeWorkspaceTests: XCTestCase {
    private func mounted(library: BibleLibrary? = nil,
                         readerFactory: @escaping @Sendable (URL) -> any BibleReading = { _ in WorkspaceBible() }) throws -> (MainWindowController, URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "NativeWorkspaceTests.\(UUID())")!
        let source = BibleSources(primary: directory.appendingPathComponent("ENG_TEST.bible"), secondary: nil, revision: 1)
        let alternate = directory.appendingPathComponent("ENG_ALT.bible")
        defaults.set(source.primary.absoluteString, forKey: AppDefaultsKey.primaryBibleName)
        defaults.set(alternate.absoluteString, forKey: AppDefaultsKey.secondaryBibleName)
        let library = library ?? BibleLibrary(preloadedURLs: [source.primary, alternate])
        let workspace = MainWorkspaceController(navigation: VerseTargetModel(readerFactory: readerFactory),
            history: HistoryStore(fileURL: directory.appendingPathComponent("history.json")),
            bookmarks: BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json")),
            library: library, defaults: defaults)
        // Projection intent is tested without opening live output on a display.
        workspace.liveProjection.projectorWindowFactory = { _ in nil }
        let controller = MainWindowController(workspace: workspace, savesFrame: false)
        controller.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        controller.window!.orderBack(nil)
        controller.window!.makeKey()
        controller.window!.contentView?.layoutSubtreeIfNeeded()
        return (controller, directory)
    }
    private func settle(_ workspace: MainWorkspaceController) async throws {
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 5_000_000)
            if !workspace.navigation.isLoading && !workspace.liveProjection.isProjecting { break }
        }
        workspace.render()
        try await Task.sleep(nanoseconds: 20_000_000)
        workspace.view.layoutSubtreeIfNeeded()
    }
    func testNativeHierarchyAndSnapshotPreserveToolbarEditor() async throws {
        let (controller, directory) = try mounted()
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        let subject = controller.workspace
        func descendants(_ controller: NSViewController) -> [NSViewController] { [controller] + controller.children.flatMap(descendants) }
        XCTAssertFalse(descendants(subject).contains { String(describing: type(of: $0)).contains("NSHostingController") })
        XCTAssertTrue(subject.searchToolbarItem?.searchField === subject.search.field)
        subject.focusSearch(nil)
        subject.search.field.stringValue = "John 3:16"
        subject.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: subject.search.field))
        let editor = try XCTUnwrap(subject.search.field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        subject.toggleBookmark(VerseReference(book: "John", chapter: 3, verse: 16)!)
        try await settle(subject)
        XCTAssertTrue(subject.search.field.currentEditor() === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertEqual(subject.search.field.stringValue, "John 3:16")
    }

    func testSearchKeyboardSelectionDoesNotPublishUntilActivated() async throws {
        let (controller, directory) = try mounted()
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        let subject = controller.workspace
        subject.changeSearchMode(.wordSearch)
        subject.search.field.stringValue = "hope"
        subject.search.field.sendAction(subject.search.field.action, to: subject.search.field.target)
        try await settle(subject)
        XCTAssertEqual(subject.verses.rows.count, 5)
        XCTAssertFalse(subject.resultsHeader.isHidden)
        XCTAssertEqual(subject.resultsHeader.frame.width, try XCTUnwrap(subject.resultsHeader.superview).bounds.width, accuracy: 0.5)
        XCTAssertNil(subject.projector.projectionOwner)
        subject.verses.table.moveDown(nil)
        XCTAssertNil(subject.projector.projectionOwner)
        subject.verses.table.insertNewline(nil)
        try await settle(subject)
        XCTAssertEqual(subject.projector.projectionOwner, .searchResult(VerseReference(book: "John", chapter: 3, verse: 2)!))
        XCTAssertTrue(subject.history.entries.isEmpty)
    }

    func testSearchSelectionIgnoresResultsFromAnOutdatedCatalog() async throws {
        let (controller, directory) = try mounted()
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        let subject = controller.workspace
        subject.changeSearchMode(.wordSearch)
        subject.search.field.stringValue = "hope"
        subject.search.field.sendAction(subject.search.field.action, to: subject.search.field.target)
        try await settle(subject)
        let selected = try XCTUnwrap(subject.verses.selectedReference)

        // Input can reach the old table before the queued catalog render runs.
        subject.library.refresh()
        XCTAssertNotNil(subject.navigation.searchPage)
        XCTAssertNil(subject.visibleSearchPage)
        subject.verses.table.moveDown(nil)
        subject.render()
        XCTAssertFalse(subject.verses.enabled)
        try await settle(subject)
        XCTAssertEqual(subject.verses.selectedReference, selected)
        XCTAssertNotNil(subject.visibleSearchPage)
        subject.verses.table.moveDown(nil)
        XCTAssertNotEqual(subject.verses.selectedReference, selected)
        XCTAssertNil(subject.projector.projectionOwner)
    }

    func testTranslationRefreshPreservesBookFilterAndBrowsing() async throws {
        let (controller, directory) = try mounted()
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        let subject = controller.workspace
        let john = VerseReference(book: "John", chapter: 3, verse: 1)!
        subject.navigate(to: john)
        try await settle(subject)
        for browsingOtherBook in [false, true] {
            if browsingOtherBook { subject.browse("Romans") }
            subject.testamentControl.selectedSegment = BibleTestament.oldTestament.rawValue
            subject.changeTestament(subject.testamentControl)
            subject.focus(.books)
            let responder = controller.window?.firstResponder
            for refreshCatalog in [false, true] {
                let previous = subject.sources
                if refreshCatalog { subject.library.refresh() }
                else { subject.setSecondaryTranslation(subject.primaryOnly ? subject.translations.secondary : nil) }
                subject.render()
                try await settle(subject)
                XCTAssertNotEqual(subject.sources, previous)
                XCTAssertEqual(subject.navigation.navigation.chapter?.sources, subject.sources)
                XCTAssertEqual(subject.browsedBook, browsingOtherBook ? "Romans" : "John")
                XCTAssertEqual(subject.browsedTestament, .oldTestament)
                XCTAssertTrue(controller.window?.firstResponder === responder)
            }
            subject.navigate(to: john)
            try await settle(subject)
            XCTAssertEqual(subject.browsedBook, "John")
            XCTAssertEqual(subject.browsedTestament, .newTestament)
        }
    }

    func testSearchHeadingMatchesVisibleRowsDuringLoadingFailureAndRetry() async throws {
        let reader = WorkspaceReadAudit()
        let (controller, directory) = try mounted(readerFactory: { _ in reader })
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        let subject = controller.workspace
        let john = VerseReference(book: "John", chapter: 3, verse: 1)!
        subject.navigate(to: john, focusVerses: false)
        try await settle(subject)
        let passageTitle = controller.window?.tab.title
        subject.changeSearchMode(.wordSearch)
        let request = TextSearchRequest(text: "hope", filter: .all, kind: .words(.term("hope")))
        subject.navigation.search(request, sources: try XCTUnwrap(subject.sources))
        subject.render()
        XCTAssertTrue(subject.navigation.isLoading)
        XCTAssertEqual(controller.window?.tab.title, passageTitle)
        XCTAssertFalse(controller.window?.tab.toolTip.hasPrefix("Search:") == true)
        XCTAssertTrue(subject.resultsHeader.isHidden)
        XCTAssertEqual(subject.verses.rows.count, 5)
        try await settle(subject)
        XCTAssertNotNil(subject.navigation.message)
        XCTAssertEqual(controller.window?.tab.title, passageTitle)
        XCTAssertTrue(subject.resultsHeader.isHidden)
        XCTAssertEqual(subject.verses.rows.count, 5)
        XCTAssertEqual(subject.navigation.searchRequest, request)

        await reader.allowSearch()
        subject.refreshSources()
        try await settle(subject)
        XCTAssertFalse(subject.resultsHeader.isHidden)
        XCTAssertEqual(controller.window?.tab.title, "Search · TEST / ALT")
        XCTAssertTrue(controller.window?.tab.toolTip.hasPrefix("Search: hope") == true)
        XCTAssertNil(subject.navigation.message)
    }

    func testEmptyLibraryDoesNotReadAndRecoversWhenCatalogBecomesAvailable() async throws {
        var catalog: [URL] = []
        let library = BibleLibrary(catalogProvider: { catalog })
        let reader = WorkspaceReadAudit()
        let (controller, directory) = try mounted(library: library, readerFactory: { _ in reader })
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        let subject = controller.workspace
        let john = VerseReference(book: "John", chapter: 3, verse: 1)!
        let preferred = subject.translations
        XCTAssertNil(subject.sources)
        XCTAssertFalse(subject.emptyLabel.isHidden)
        XCTAssertEqual(subject.emptyLabel.stringValue, BibleLibraryError.empty.localizedDescription)
        XCTAssertFalse(subject.primaryPicker.isEnabled)
        XCTAssertFalse(subject.secondaryPicker.isEnabled)
        XCTAssertFalse(subject.secondaryPicker.isHidden)
        subject.navigate(to: john, project: true, recordHistory: true)
        subject.activateVerse(john)
        subject.changeSearchMode(.wordSearch)
        subject.search.field.stringValue = "hope"
        subject.search.field.sendAction(subject.search.field.action, to: subject.search.field.target)
        try await settle(subject)
        let reads = await reader.reads
        XCTAssertEqual(reads, 0)
        XCTAssertNil(subject.projector.projectionOwner)
        XCTAssertTrue(subject.history.entries.isEmpty)
        XCTAssertEqual(subject.emptyLabel.stringValue, BibleLibraryError.empty.localizedDescription)

        catalog = [directory.appendingPathComponent("ENG_TEST.bible"), directory.appendingPathComponent("ENG_ALT.bible")]
        library.refresh()
        try await settle(subject)
        XCTAssertNotNil(subject.sources)
        XCTAssertTrue(subject.primaryPicker.isEnabled)
        XCTAssertTrue(subject.secondaryPicker.isEnabled)
        XCTAssertEqual(subject.translations, preferred)
        XCTAssertNil(subject.navigation.message)
        subject.navigate(to: john, project: true)
        try await settle(subject)
        XCTAssertEqual(subject.projector.projectionOwner?.reference, john)
        subject.changeSearchMode(.verseReference)
        try await settle(subject)
        XCTAssertFalse(subject.verses.rows.isEmpty)
        XCTAssertTrue(subject.emptyLabel.isHidden)
        subject.liveProjection.shutdown()
    }

    func testChoosingDisplayedFallbackReplacesMissingPreference() async throws {
        let primary = URL(fileURLWithPath: "/fixtures/ENG_TEST.bible")
        let alternate = URL(fileURLWithPath: "/fixtures/ENG_ALT.bible")
        var catalog = [primary, alternate]
        let library = BibleLibrary(catalogProvider: { catalog })
        let (controller, directory) = try mounted(library: library)
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        let subject = controller.workspace
        let preferred = subject.translations.primary
        catalog = [alternate]
        library.refresh()
        try await settle(subject)
        XCTAssertEqual(subject.sources?.primary, alternate)
        XCTAssertEqual(subject.translations.primary, preferred)
        // Choosing the already-displayed fallback is an explicit preference change.
        subject.primaryPicker.sendAction(subject.primaryPicker.action, to: subject.primaryPicker.target)
        XCTAssertEqual(subject.translations.primary, alternate)
        XCTAssertEqual(subject.defaults.string(forKey: AppDefaultsKey.primaryBibleName), alternate.absoluteString)
        catalog = [primary, alternate]
        library.refresh()
        try await settle(subject)
        XCTAssertEqual(subject.sources?.primary, alternate)
        XCTAssertEqual(subject.library.defaultTranslations(subject.defaults).primary, alternate)
    }

    func testTranslationPickersAndTabHeadingsFollowOnlyTheirOwnPassageAndLiveOwnership() async throws {
        let (first, directory) = try mounted()
        let a = first.workspace
        let b = MainWorkspaceController(navigation: VerseTargetModel(readerFactory: { _ in WorkspaceBible() }),
            history: a.history, bookmarks: a.bookmarks, translations: a.translations, liveProjection: a.liveProjection)
        let second = MainWindowController(workspace: b, savesFrame: false)
        defer { first.close(); second.close(); a.liveProjection.shutdown(); try? FileManager.default.removeItem(at: directory) }
        func choose(_ url: URL?, in picker: NSPopUpButton) throws {
            let index = try XCTUnwrap(picker.itemArray.firstIndex { ($0.representedObject as? String) == (url?.absoluteString ?? "") })
            picker.selectItem(at: index)
            picker.sendAction(picker.action, to: picker.target)
        }
        let john = VerseReference(book: "John", chapter: 3, verse: 1)!
        let psalm = VerseReference(book: "Psalm", chapter: 23, verse: 2)!
        try await settle(a); try await settle(b)
        XCTAssertEqual(first.window?.tab.title, "New Passage · TEST / ALT")
        a.navigate(to: john, project: true)
        b.navigate(to: psalm)
        try await settle(a); try await settle(b)
        XCTAssertEqual(first.window?.tab.title, "● Live · John 3:1 · TEST / ALT")
        XCTAssertEqual(second.window?.tab.title, "Psalm 23:2 · TEST / ALT")
        let originalRevision = a.projector.revision
        let originalChoices = a.translations
        try choose(originalChoices.primary, in: b.secondaryPicker)
        try choose(originalChoices.secondary, in: b.primaryPicker)
        try choose(nil, in: b.secondaryPicker)
        try await settle(b); a.render()
        XCTAssertEqual(a.translations, originalChoices)
        XCTAssertEqual(a.projector.revision, originalRevision)
        XCTAssertEqual(second.window?.tab.title, "Psalm 23:2 · ALT")
        XCTAssertEqual(b.translations.secondary, originalChoices.primary)
        XCTAssertNil(b.sources?.secondary)
        XCTAssertFalse(b.secondaryPicker.isHidden)
        XCTAssertEqual(b.secondaryPicker.selectedItem?.title, "None")
        XCTAssertTrue(second.window?.tab.toolTip.contains("English · ALT") == true)
        try choose(originalChoices.primary, in: b.secondaryPicker)
        try await settle(b); a.render()
        XCTAssertEqual(b.sources?.secondary, originalChoices.primary, "Choosing a secondary translation immediately restores both texts")
        XCTAssertTrue(b.verses.rows.allSatisfy { $0.secondaryText != nil })
        XCTAssertEqual(second.window?.tab.title, "Psalm 23:2 · ALT / TEST")
        XCTAssertEqual(a.projector.revision, originalRevision)
        try choose(nil, in: b.secondaryPicker)
        try await settle(b)

        b.navigate(to: john)
        try await settle(b)
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: second.window!.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49)!
        b.verses.table.keyDown(with: space)
        try await settle(b)
        XCTAssertEqual(a.liveProjection.source?.tabID, b.tabID, "Space must project the same verse in this tab's different translation")
        XCTAssertEqual(a.projector.projectorViewData.primaryTranslationName, "English · ALT")
        b.verses.table.keyDown(with: space)
        try await settle(b)
        XCTAssertFalse(a.windowOpened, "Space stops output when both the reference and translations already match")
        b.navigate(to: psalm)
        try await settle(b)
        b.activateVerse(psalm)
        try await settle(b); a.render()
        XCTAssertEqual(a.liveProjection.source?.tabID, b.tabID)
        XCTAssertEqual(first.window?.tab.title, "John 3:1 · TEST / ALT")
        XCTAssertNil(first.window?.tab.attributedTitle)
        XCTAssertEqual(second.window?.tab.title, "● Live · Psalm 23:2 · ALT")
        XCTAssertEqual(second.window?.tab.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemGreen)
        a.toggleBlank(nil)
        b.browse("Genesis")
        try await settle(b)
        XCTAssertEqual(second.window?.tab.title, "● Blanked · Genesis · ALT")
        XCTAssertEqual(second.window?.tab.attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
        XCTAssertTrue(second.window?.tab.toolTip.contains("Blanked from this tab: Psalm 23:2") == true)
        a.closeProjector()
        try await settle(a); b.render()
        XCTAssertEqual(second.window?.tab.title, "Genesis · ALT")
        XCTAssertNil(second.window?.tab.attributedTitle)
    }

    func testBookmarkClearUndoUsesWindowResponderChain() throws {
        let (controller, directory) = try mounted()
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        let subject = controller.workspace
        let reference = VerseReference(book: "Psalm", chapter: 23, verse: 1)!
        subject.bookmarks.add(reference)
        subject.bookmarks.clear(undoManager: controller.window?.undoManager)
        XCTAssertFalse(subject.bookmarks.contains(reference))
        XCTAssertTrue(subject.verses.table.tryToPerform(#selector(MainWindowController.undo(_:)), with: nil))
        XCTAssertTrue(subject.bookmarks.contains(reference))
    }

    func testChapterButtonReactivationKeepsSelectionAndHighlight() async throws {
        let (controller, directory) = try mounted()
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        controller.workspace.browse("John")
        try await settle(controller.workspace)
        let chapters = controller.workspace.chapters
        let initial = VerseReference(book: "John", chapter: 2, verse: 1)!
        let target = VerseReference(book: "John", chapter: 3, verse: 1)!
        var activations: [VerseReference] = []
        chapters.onActivate = { activations.append($0) }
        chapters.apply(book: "John", selection: initial)
        chapters.view.layoutSubtreeIfNeeded()
        let path = IndexPath(item: 2, section: 0)
        let button = try XCTUnwrap(chapters.collection.item(at: path)?.view as? NSButton)
        for count in 1...2 {
            button.performClick(nil)
            XCTAssertEqual(activations, Array(repeating: target, count: count))
            XCTAssertEqual(chapters.selectedReference, target)
            XCTAssertEqual(chapters.collection.selectionIndexPaths, [path])
            XCTAssertEqual(button.state, .on)
        }
    }

    func testDeferredCloseDoesNotClearANewerProjection() async throws {
        let (controller, directory) = try mounted()
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        let subject = controller.workspace
        let old = VerseReference(book: "John", chapter: 3, verse: 16)!
        let new = VerseReference(book: "John", chapter: 3, verse: 17)!
        subject.projector.project(.empty, owner: .textInputTarget(old))
        subject.liveProjection.handleProjectorWindowClosed()
        subject.projector.project(.empty, owner: .verseRowSelection(new))
        try await settle(subject)
        XCTAssertEqual(subject.projector.projectionOwner, .verseRowSelection(new))
        subject.liveProjection.handleProjectorWindowClosed()
        try await settle(subject)
        XCTAssertNil(subject.projector.projectionOwner)
    }
}
