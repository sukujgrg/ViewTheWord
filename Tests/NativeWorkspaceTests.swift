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

@MainActor
final class NativeWorkspaceTests: XCTestCase {
    private func mounted() throws -> (MainWindowController, URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "NativeWorkspaceTests.\(UUID())")!
        let source = BibleSources(primary: directory.appendingPathComponent("ENG_TEST.bible"), secondary: nil, revision: 1)
        let workspace = MainWorkspaceController(navigation: VerseTargetModel(readerFactory: { _ in WorkspaceBible() }),
            history: HistoryStore(fileURL: directory.appendingPathComponent("history.json")),
            bookmarks: BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json")), defaults: defaults,
            sourceResolver: { _ in source })
        // Projection intent is tested without opening live output on a display.
        workspace.projectorWindowFactory = { _ in nil }
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
            if !workspace.navigation.isLoading && !workspace.navigation.isProjecting { break }
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

    func testDeferredCloseDoesNotClearANewerProjection() async throws {
        let (controller, directory) = try mounted()
        defer { controller.close(); try? FileManager.default.removeItem(at: directory) }
        let subject = controller.workspace
        let old = VerseReference(book: "John", chapter: 3, verse: 16)!
        let new = VerseReference(book: "John", chapter: 3, verse: 17)!
        subject.projector.project(.empty, owner: .textInputTarget(old))
        subject.handleProjectorWindowClosed()
        subject.projector.project(.empty, owner: .verseRowSelection(new))
        try await settle(subject)
        XCTAssertEqual(subject.projector.projectionOwner, .verseRowSelection(new))
        subject.handleProjectorWindowClosed()
        try await settle(subject)
        XCTAssertNil(subject.projector.projectionOwner)
    }
}
