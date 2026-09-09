import AppKit
import XCTest
@testable import ViewTheWordCore

/// A noncooperative database: canceled work can still return after another tab's
/// intent. These gates exercise ordering instead of depending on task timing.
private actor PassageBible: BibleReading {
    private var chapters: [VerseReference: CheckedContinuation<[AVerse], Error>] = [:]
    private var lookups: [VerseReference: CheckedContinuation<[AVerse], Error>] = [:]
    func chapter(_ reference: VerseReference) async throws -> [AVerse] {
        try await withCheckedThrowingContinuation { chapters[reference] = $0 }
    }
    func verses(_ references: [VerseReference]) async throws -> [AVerse] {
        guard let reference = references.first else { return [] }
        return try await withCheckedThrowingContinuation { lookups[reference] = $0 }
    }
    func search(_ request: TextSearchRequest, after: VerseCoordinate?, limit: Int) async throws -> [AVerse] { [] }
    func waiting(_ reference: VerseReference, lookup: Bool) -> Bool { lookup ? lookups[reference] != nil : chapters[reference] != nil }
    func finish(_ reference: VerseReference, lookup: Bool = false, text: String = "Test verse", available: Bool = true) {
        let pending = lookup ? lookups.removeValue(forKey: reference) : chapters.removeValue(forKey: reference)
        pending?.resume(returning: available ? [AVerse(reference: reference, verse: text)] : [])
    }
}

@MainActor
private final class HiddenProjectionWindow: NSWindow {
    override func orderFrontRegardless() {} // Exercise real window lifetime without display output.
}

@MainActor
final class PassageProjectionTests: XCTestCase {
    private let john = VerseReference(book: "John", chapter: 3, verse: 16)!
    private let romans = VerseReference(book: "Romans", chapter: 8, verse: 28)!
    private let psalm = VerseReference(book: "Psalm", chapter: 23, verse: 1)!

    @MainActor private final class Fixture {
        let reader = PassageBible()
        let live: LiveProjectionController
        let first: MainWorkspaceController
        let second: MainWorkspaceController
        let defaultsName = "PassageProjectionTests.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var opens = 0
        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let defaults = UserDefaults(suiteName: defaultsName)!
            let source = directory.appendingPathComponent("ENG_TEST.bible")
            let reader = reader
            live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [source]), defaults: defaults, sourceResolver: {
                BibleSources(primary: source, secondary: nil, revision: $0 ? 2 : 1)
            }, refreshReader: VerseTargetModel(readerFactory: { _ in reader }))
            let history = HistoryStore(fileURL: directory.appendingPathComponent("history.json"))
            let bookmarks = BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json"))
            first = MainWorkspaceController(navigation: VerseTargetModel(readerFactory: { _ in reader }), history: history, bookmarks: bookmarks, liveProjection: live)
            second = MainWorkspaceController(navigation: VerseTargetModel(readerFactory: { _ in reader }), history: history, bookmarks: bookmarks, liveProjection: live)
            live.projectorWindowFactory = { [weak self] _ in self?.opens += 1; return nil }
        }
        func cleanUp() {
            first.shutdown(); second.shutdown(); live.shutdown()
            live.defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func eventually(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Asynchronous operation did not complete", file: file, line: line)
        throw NSError(domain: "PassageProjectionTests", code: 1)
    }
    private func finish(_ fixture: Fixture, reference: VerseReference, lookup: Bool = false, text: String = "Test verse", available: Bool = true) async throws {
        try await eventually { await fixture.reader.waiting(reference, lookup: lookup) }
        await fixture.reader.finish(reference, lookup: lookup, text: text, available: available)
    }

    func testOneOwnedWindowSurvivesWorkspaceClosureAndReopensAfterStop() async throws {
        _ = NSApplication.shared
        let f = try Fixture(); defer { f.cleanUp() }
        var windows: [NSWindow] = []
        f.live.projectorWindowFactory = { _ in
            let window = HiddenProjectionWindow(contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100),
                                                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            windows.append(window)
            return window
        }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        let original = try XCTUnwrap(f.live.ownedProjectorWindow)
        f.second.navigate(to: romans, project: true)
        try await finish(f, reference: romans)
        try await eventually { f.live.projector.projectionOwner?.reference == self.romans }
        f.second.shutdown()
        XCTAssertTrue(f.live.ownedProjectorWindow === original)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(original.windowController)
        f.live.closeProjector()
        try await eventually { !f.live.windowOpened }
        XCTAssertNil(f.live.ownedProjectorWindow)
        let row = try XCTUnwrap(f.first.navigation.prepareRowProjection(john, sources: f.first.sources))
        f.live.publishRow(row)
        let replacement = try XCTUnwrap(f.live.ownedProjectorWindow)
        XCTAssertFalse(replacement === original)
        XCTAssertEqual(windows.count, 2)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: original)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(f.live.ownedProjectorWindow === replacement)
        XCTAssertEqual(f.live.projector.projectionOwner?.reference, john)
    }

    func testNewerTabSubmissionSupersedesEarlierSlowNavigation() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true, recordHistory: true)
        try await eventually { await f.reader.waiting(self.john, lookup: false) }
        f.second.navigate(to: romans, project: true)
        try await finish(f, reference: romans)
        try await eventually { f.live.projector.projectionOwner?.reference == self.romans }
        await f.reader.finish(john)
        try await eventually { !f.first.navigation.isLoading }
        XCTAssertEqual(f.first.navigation.navigation.reference, john)
        XCTAssertEqual(f.second.navigation.navigation.reference, romans)
        XCTAssertEqual(f.live.projector.projectionOwner?.reference, romans)
        XCTAssertEqual(f.first.history.entries.map(\.title), [john.verseQuery.title])
        XCTAssertTrue(f.first.history === f.second.history)
        XCTAssertEqual(f.opens, 1)
    }

    func testStopFromAnotherTabCancelsPendingOutputButAllowsNavigation() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await eventually { await f.reader.waiting(self.john, lookup: false) }
        XCTAssertTrue(f.second.liveProjection.isProjecting)
        f.second.stopProjection(nil)
        await f.reader.finish(john)
        try await eventually { !f.first.navigation.isLoading && !f.live.isProjecting }
        XCTAssertEqual(f.first.navigation.navigation.reference, john)
        XCTAssertNil(f.live.projector.projectionOwner)
        XCTAssertEqual(f.opens, 0)
        f.live.requestProjection(owner: .searchResult(romans), using: f.first.navigation)
        try await eventually { await f.reader.waiting(self.romans, lookup: true) }
        f.second.closeProjector()
        await f.reader.finish(romans, lookup: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(f.live.projector.projectionOwner)
        XCTAssertFalse(f.live.isProjecting)
        XCTAssertEqual(f.opens, 0)
    }

    func testLocalSubmissionCancellationLeavesAnotherTabsRequestAlone() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await eventually { await f.reader.waiting(self.john, lookup: false) }
        f.live.requestProjection(owner: .searchResult(romans), using: f.second.navigation)
        f.first.navigation.cancelLoading(clearSearch: true)
        await f.reader.finish(john)
        XCTAssertTrue(f.live.isProjecting)
        try await finish(f, reference: romans, lookup: true)
        try await eventually { f.live.projector.projectionOwner?.reference == self.romans }
        XCTAssertEqual(f.opens, 1)
    }

    func testCancelingOwnSubmissionDoesNotPublishLateResult() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await eventually { await f.reader.waiting(self.john, lookup: false) }
        f.first.browse("Romans")
        await f.reader.finish(john)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(f.live.isProjecting)
        XCTAssertNil(f.live.projector.projectionOwner)
        XCTAssertEqual(f.opens, 0)
    }

    func testSharedTranslationRefreshSurvivesBrowsingAndOriginatingTabClosure() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        f.second.toggleBlank(nil)
        f.live.defaults.set(true, forKey: AppDefaultsKey.showOnlyPrimary)
        f.live.refreshPreferences()
        f.first.shutdown()
        f.second.navigate(to: romans, focusVerses: false)
        try await finish(f, reference: romans)
        try await finish(f, reference: john, lookup: true, text: "Refreshed translation")
        try await eventually { f.live.projector.projectorViewData.primaryText == "Refreshed translation" }
        XCTAssertTrue(f.live.projector.isBlanked)
        XCTAssertEqual(f.live.projector.projectionOwner?.reference, john)
        XCTAssertEqual(f.second.navigation.navigation.reference, romans)
        XCTAssertEqual(f.opens, 1)
    }

    func testUnavailableSharedRefreshStopsOutput() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        f.first.shutdown()
        f.live.defaults.set(true, forKey: AppDefaultsKey.showOnlyPrimary)
        f.live.refreshPreferences()
        try await finish(f, reference: john, lookup: true, available: false)
        try await eventually { !f.live.windowOpened }
        XCTAssertNil(f.live.projector.projectionOwner)
    }

    func testDeferredCloseClearsOldOutputWhilePreservingNewPendingRequest() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        f.first.closeProjector()
        f.live.requestProjection(owner: .searchResult(psalm), using: f.second.navigation)
        try await eventually { await f.reader.waiting(self.psalm, lookup: true) }
        XCTAssertTrue(f.live.isProjecting)
        XCTAssertNil(f.live.projector.projectionOwner)
        XCTAssertFalse(f.live.windowOpened)
        try await finish(f, reference: psalm, lookup: true)
        try await eventually { f.live.projector.projectionOwner?.reference == self.psalm }
        XCTAssertEqual(f.opens, 2)
        // Synchronous row publication also survives an earlier close callback.
        let row = f.first.navigation.prepareRowProjection(john, sources: f.first.sources)!
        f.live.closeProjector()
        f.live.publishRow(row)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(f.live.projector.projectionOwner?.reference, john)
        XCTAssertTrue(f.live.windowOpened)
    }
}
