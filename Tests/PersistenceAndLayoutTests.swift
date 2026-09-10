import XCTest
import AppKit
@testable import ViewTheWordCore

@MainActor
final class PersistenceAndLayoutTests: XCTestCase {
    func testCorruptHistoryAndBookmarksArePreservedBeforeSaving() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = Data("unreadable original".utf8)
        let historyURL = directory.appendingPathComponent("history.json")
        let bookmarkURL = directory.appendingPathComponent("bookmarks.json")
        try corrupt.write(to: historyURL); try corrupt.write(to: bookmarkURL)
        let history = HistoryStore(fileURL: historyURL)
        let bookmarks = BookmarkStore(fileURL: bookmarkURL)
        XCTAssertNotNil(history.issue); XCTAssertNotNil(bookmarks.issue)
        XCTAssertEqual(try Data(contentsOf: historyURL), corrupt)
        XCTAssertEqual(try Data(contentsOf: bookmarkURL), corrupt)
        history.append("John 3:16")
        bookmarks.add(VerseReference(book: "John", chapter: 3, verse: 16)!)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("recovery-") }
        XCTAssertEqual(backups.count, 2)
        for backup in backups { XCTAssertEqual(try Data(contentsOf: backup), corrupt) }
        XCTAssertEqual(HistoryStore(fileURL: historyURL).entries.count, 1)
        XCTAssertEqual(BookmarkStore(fileURL: bookmarkURL).entries.count, 1)
    }

    func testInvalidStoredReferencesPreserveOriginalAndRetainValidEntries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let original = try JSONEncoder().encode(["John 3: 16", "John 3:16", "John 3:2147483648"])
        try original.write(to: url)
        let history = HistoryStore(fileURL: url)
        XCTAssertNotNil(history.issue)
        XCTAssertEqual(history.entries.map(\.title), ["John 3:16"])
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.contains("recovery-") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    func testHistoryLegacyReferenceResolvesIndependentlyOfSearchMode() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        try JSONEncoder().encode(["John 3: 16"]).write(to: url)
        let history = HistoryStore(fileURL: url)
        let query = try SearchQuery(ask: XCTUnwrap(history.entries.first?.title)).validatedVerseQuery()
        XCTAssertEqual(VerseReference(query), VerseReference(book: "John", chapter: 3, verse: 16))
    }

    func testSanitizedStoresPersistRepairAndDoNotRepeatRecoveryOnReload() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyURL = directory.appendingPathComponent("history.json")
        let bookmarkURL = directory.appendingPathComponent("bookmarks.json")
        let now = Date()
        let historyData = try JSONEncoder().encode([
            HistoryStore.Entry(title: "John 3:16", selectedAt: now),
            HistoryStore.Entry(title: "Invalid reference", selectedAt: now)
        ])
        let bookmarkData = try JSONSerialization.data(withJSONObject: [
            ["book": "John", "chapter": 3, "verse": 16, "createdAt": now.timeIntervalSinceReferenceDate],
            ["book": "Unknown book", "chapter": 3, "verse": 16, "createdAt": now.timeIntervalSinceReferenceDate]
        ])
        try historyData.write(to: historyURL)
        try bookmarkData.write(to: bookmarkURL)
        let history = HistoryStore(fileURL: historyURL)
        let bookmarks = BookmarkStore(fileURL: bookmarkURL)
        XCTAssertNotNil(history.issue)
        XCTAssertNotNil(bookmarks.issue)
        XCTAssertEqual(history.entries.map(\.title), ["John 3:16"])
        XCTAssertEqual(bookmarks.entries.compactMap(\.reference), [VerseReference(book: "John", chapter: 3, verse: 16)!])
        XCTAssertEqual(try JSONDecoder().decode([HistoryStore.Entry].self, from: Data(contentsOf: historyURL)), history.entries)
        XCTAssertEqual(try JSONDecoder().decode([BookmarkStore.Entry].self, from: Data(contentsOf: bookmarkURL)), bookmarks.entries)

        let reloadedHistory = HistoryStore(fileURL: historyURL)
        let reloadedBookmarks = BookmarkStore(fileURL: bookmarkURL)
        XCTAssertNil(reloadedHistory.issue)
        XCTAssertNil(reloadedBookmarks.issue)
        XCTAssertEqual(reloadedHistory.entries, history.entries)
        XCTAssertEqual(reloadedBookmarks.entries, bookmarks.entries)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("recovery-") }
        XCTAssertEqual(backups.count, 2)
        for backup in backups {
            XCTAssertEqual(try Data(contentsOf: backup), backup.lastPathComponent.hasPrefix("history.") ? historyData : bookmarkData)
        }
    }

    func testClearBookmarksCanBeUndoneAndRedone() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bookmarks = BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json"))
        let reference = VerseReference(book: "John", chapter: 3, verse: 16)!
        bookmarks.add(reference)
        let undo = UndoManager()
        undo.beginUndoGrouping()
        bookmarks.clear(undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertTrue(bookmarks.entries.isEmpty)
        undo.undo()
        XCTAssertTrue(bookmarks.contains(reference))
        undo.redo()
        XCTAssertTrue(bookmarks.entries.isEmpty)
    }

    func testSaveFailureIsVisible() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("file-instead-of-folder")
        try Data().write(to: blocker)
        let store = BookmarkStore(fileURL: blocker.appendingPathComponent("bookmarks.json"))
        store.add(VerseReference(book: "John", chapter: 3, verse: 16)!)
        XCTAssertNotNil(store.issue)
    }

    func testUndoClearPreservesLaterBookmarksAndRedoOnlyClearsRestoredEntries() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmarks.json")
        let bookmarks = BookmarkStore(fileURL: url)
        let old = VerseReference(book: "John", chapter: 3, verse: 16)!
        let new = VerseReference(book: "John", chapter: 3, verse: 17)!
        let undo = UndoManager()
        undo.groupsByEvent = false
        bookmarks.add(old)
        undo.beginUndoGrouping()
        bookmarks.clear(undoManager: undo)
        undo.endUndoGrouping()
        bookmarks.add(new)

        undo.undo()
        XCTAssertTrue(bookmarks.contains(old))
        XCTAssertTrue(bookmarks.contains(new))
        XCTAssertTrue(BookmarkStore(fileURL: url).contains(new))
        undo.redo()
        XCTAssertFalse(bookmarks.contains(old))
        XCTAssertTrue(bookmarks.contains(new))
        XCTAssertEqual(BookmarkStore(fileURL: url).entries.map(\.reference), [new])
    }

    func testBookmarkEditsUndoInOrderAndPersistRedo() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmarks.json")
        let bookmarks = BookmarkStore(fileURL: url)
        let old = VerseReference(book: "John", chapter: 3, verse: 16)!
        let new = VerseReference(book: "John", chapter: 3, verse: 17)!
        let undo = UndoManager()
        undo.groupsByEvent = false
        func edit(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
        }
        bookmarks.add(old)
        edit { bookmarks.clear(undoManager: undo) }
        edit { bookmarks.add(new, undoManager: undo) }
        edit { bookmarks.remove(new, undoManager: undo) }
        XCTAssertEqual(undo.undoActionName, "Remove Bookmark")
        undo.undo()
        XCTAssertEqual(bookmarks.entries.map(\.reference), [new])
        XCTAssertEqual(undo.undoActionName, "Add Bookmark")
        undo.undo()
        XCTAssertTrue(bookmarks.entries.isEmpty)
        XCTAssertEqual(undo.undoActionName, "Clear Bookmarks")
        undo.undo()
        XCTAssertEqual(bookmarks.entries.map(\.reference), [old])
        undo.redo()
        undo.redo()
        XCTAssertEqual(BookmarkStore(fileURL: url).entries.map(\.reference), [new])
        undo.redo()
        XCTAssertTrue(BookmarkStore(fileURL: url).entries.isEmpty)
    }

    func testFractionalRegionDoesNotCollapseFontSize() {
        let text = String(repeating: "The king wrote to every province. ", count: 12)
        let size = ProjectorTextLayout.fontSize(for: text, in: CGSize(width: 203.4, height: 206.6), preferred: 200)
        XCTAssertGreaterThan(size, 8)
    }

    func testLongMalayalamAndRTLTextFitSmallOutputRegions() {
        for text in [String(repeating: "ദൈവം ലോകത്തെ സ്നേഹിച്ചു. ", count: 35), String(repeating: "For God so loved the world; ", count: 35), String(repeating: "בראשית ברא אלהים ", count: 35)] {
            for region in [CGSize(width: 440, height: 230), CGSize(width: 180, height: 140), CGSize(width: 203.4, height: 206.6)] {
                let size = ProjectorTextLayout.fontSize(for: text, in: region, preferred: 200)
                let measured = ProjectorTextLayout.measuredSize(text, width: region.width, fontSize: size)
                XCTAssertGreaterThan(size, 1)
                XCTAssertLessThan(size, 200)
                XCTAssertLessThanOrEqual(measured.height, region.height)
                XCTAssertLessThanOrEqual(measured.width, region.width)
            }
        }
    }
}
