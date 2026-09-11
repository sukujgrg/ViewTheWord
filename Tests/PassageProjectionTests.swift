import AppKit
import XCTest
@testable import ViewTheWordCore

/// A noncooperative database: canceled work can still return after another tab's
/// intent. These gates exercise ordering instead of depending on task timing.
private actor PassageBible: BibleReading {
    private var chapters: [VerseReference: CheckedContinuation<[AVerse], Error>] = [:]
    private var lookups: [VerseReference: CheckedContinuation<[AVerse], Error>] = [:]
    func chapter(_ reference: VerseReference) async throws -> [AVerse] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { chapters[reference] = $0 }
    }
    func verses(_ references: [VerseReference]) async throws -> [AVerse] {
        try Task.checkCancellation()
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
        let alternateReader = PassageBible()
        let primary: URL
        let alternate: URL
        let live: LiveProjectionController
        let first: MainWorkspaceController
        let second: MainWorkspaceController
        let defaultsName = "PassageProjectionTests.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var opens = 0
        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let defaults = UserDefaults(suiteName: defaultsName)!
            primary = directory.appendingPathComponent("ENG_NIV.bible")
            alternate = directory.appendingPathComponent("ENG_NLT.bible")
            defaults.set(primary.absoluteString, forKey: AppDefaultsKey.primaryBibleName)
            defaults.set(alternate.absoluteString, forKey: AppDefaultsKey.secondaryBibleName)
            defaults.set(true, forKey: AppDefaultsKey.showOnlyPrimary)
            let factory: @Sendable (URL) -> any BibleReading = { [reader, alternateReader, primary] in
                $0 == primary ? reader : alternateReader
            }
            live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [primary, alternate]), defaults: defaults,
                                            refreshReader: VerseTargetModel(readerFactory: factory))
            let history = HistoryStore(fileURL: directory.appendingPathComponent("history.json"))
            let bookmarks = BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json"))
            first = MainWorkspaceController(navigation: VerseTargetModel(readerFactory: factory), history: history, bookmarks: bookmarks, liveProjection: live)
            second = MainWorkspaceController(navigation: VerseTargetModel(readerFactory: factory), history: history, bookmarks: bookmarks, liveProjection: live)
            live.projectorWindowFactory = { [weak self] _ in self?.opens += 1; return nil }
        }
        func useAlternate(in workspace: MainWorkspaceController) {
            var selection = workspace.translations
            selection.primary = alternate
            workspace.setTranslations(selection)
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
    private func finish(_ fixture: Fixture, reference: VerseReference, lookup: Bool = false, alternate: Bool = false,
                        text: String = "Test verse", available: Bool = true) async throws {
        let reader = alternate ? fixture.alternateReader : fixture.reader
        try await eventually { await reader.waiting(reference, lookup: lookup) }
        await reader.finish(reference, lookup: lookup, text: text, available: available)
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
        f.live.publishRow(row, from: f.first.tabID)
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
        f.live.requestProjection(owner: .searchResult(romans), from: f.first.tabID, sources: f.first.sources, using: f.first.navigation)
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
        f.live.requestProjection(owner: .searchResult(romans), from: f.second.tabID, sources: f.second.sources, using: f.second.navigation)
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

    func testSourceTabTranslationRefreshSurvivesBrowsingAndOriginatingTabClosure() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        f.second.toggleBlank(nil)
        f.useAlternate(in: f.first)
        f.first.shutdown()
        f.second.navigate(to: romans, focusVerses: false)
        try await finish(f, reference: romans)
        try await finish(f, reference: john, lookup: true, alternate: true, text: "Refreshed translation")
        try await eventually { f.live.projector.projectorViewData.primaryText == "Refreshed translation" }
        XCTAssertTrue(f.live.projector.isBlanked)
        XCTAssertEqual(f.live.projector.projectionOwner?.reference, john)
        XCTAssertEqual(f.second.navigation.navigation.reference, romans)
        XCTAssertEqual(f.opens, 1)
        XCTAssertNil(f.live.source?.tabID)
        XCTAssertEqual(f.live.source?.sources.primary, f.alternate)
    }

    func testOtherTabsRememberedTranslationsLeaveLiveAndPendingOutputUntouched() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        let source = f.live.source
        let revision = f.live.projector.revision
        f.useAlternate(in: f.second)
        f.second.setSecondaryTranslation(f.primary)
        f.first.render(); f.second.render(); f.live.refreshPreferences()
        XCTAssertEqual(f.live.source, source)
        XCTAssertEqual(f.live.projector.revision, revision)
        XCTAssertEqual(f.first.sources.primary, f.primary)
        XCTAssertNil(f.first.sources.secondary)
        XCTAssertEqual(f.second.sources.primary, f.alternate)
        let next = MainWorkspaceController(history: f.first.history, bookmarks: f.first.bookmarks, liveProjection: f.live)
        XCTAssertEqual(next.translations, f.second.translations)
        next.shutdown()

        f.first.navigate(to: romans, project: true)
        try await eventually { await f.reader.waiting(self.romans, lookup: false) }
        f.second.setSecondaryTranslation(nil)
        try await finish(f, reference: romans)
        try await eventually { f.live.projector.projectionOwner?.reference == self.romans }
        XCTAssertEqual(f.live.source?.tabID, f.first.tabID)
        XCTAssertEqual(f.live.source?.sources, f.first.sources)
    }

    func testSourceRefreshKeepsLiveReferenceAndBlankingAfterBrowsingElsewhere() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        f.first.navigate(to: romans)
        try await finish(f, reference: romans)
        try await eventually { !f.first.navigation.isLoading }
        let draft = f.first.draft
        f.second.toggleBlank(nil)
        f.useAlternate(in: f.first)
        try await finish(f, reference: romans, alternate: true)
        try await eventually { !f.first.navigation.isLoading }
        f.first.browse("Genesis")
        try await finish(f, reference: john, lookup: true, alternate: true, text: "NLT live verse")
        try await eventually { f.live.projector.projectorViewData.primaryText == "NLT live verse" }
        XCTAssertEqual(f.live.projector.projectionOwner?.reference, john)
        XCTAssertEqual(f.live.source?.tabID, f.first.tabID)
        XCTAssertEqual(f.live.source?.sources, f.first.sources)
        XCTAssertTrue(f.live.projector.isBlanked)
        XCTAssertEqual(f.first.browsedBook, "Genesis")
        XCTAssertEqual(f.first.draft, draft)
        XCTAssertEqual(f.second.sources.primary, f.primary)
    }

    func testSecondaryNoneIsLocalAndRefreshesSourceOutput() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        let revision = f.live.projector.revision
        var selection = f.first.translations
        selection.secondary = f.primary
        f.first.setTranslations(selection)
        XCTAssertFalse(f.first.navigation.isLoading, "Changing an unused secondary choice must not restart the passage")
        XCTAssertEqual(f.live.projector.revision, revision)
        selection.secondary = f.alternate
        f.first.setTranslations(selection)
        f.first.setSecondaryTranslation(f.alternate)
        try await finish(f, reference: john)
        try await finish(f, reference: john, alternate: true)
        try await finish(f, reference: john, lookup: true, text: "Primary live verse")
        try await finish(f, reference: john, lookup: true, alternate: true, text: "Secondary live verse")
        try await eventually { f.live.projector.projectorViewData.secondaryText == "Secondary live verse" }
        XCTAssertEqual(f.live.source?.sources.secondary, f.alternate)
        XCTAssertTrue(f.second.primaryOnly)
        f.first.setSecondaryTranslation(nil)
        try await finish(f, reference: john)
        try await finish(f, reference: john, lookup: true)
        try await eventually { f.live.projector.projectorViewData.secondaryText == nil }
        XCTAssertEqual(f.first.translations.secondary, f.alternate)
        XCTAssertNil(f.live.source?.sources.secondary)
    }

    func testNewSessionRestoresLastTranslationSelectionIncludingNone() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        let original = f.first.translations
        f.useAlternate(in: f.second)
        for secondary in [Optional(f.primary), nil] {
            f.second.setSecondaryTranslation(secondary)
            let live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [f.primary, f.alternate]),
                                                defaults: try XCTUnwrap(UserDefaults(suiteName: f.defaultsName)))
            let reopened = MainWorkspaceController(history: f.first.history, bookmarks: f.first.bookmarks, liveProjection: live)
            XCTAssertEqual(reopened.translations, f.second.translations)
            XCTAssertEqual(reopened.sources.secondary, secondary)
            XCTAssertEqual(f.first.translations, original, "Remembering another tab's choices cannot change an existing tab")
            reopened.shutdown()
            live.shutdown()
        }
    }

    func testSourceTranslationChangeWaitsForAnotherTabsExplicitProjection() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        f.second.navigate(to: romans, project: true)
        try await eventually { await f.reader.waiting(self.romans, lookup: false) }
        f.useAlternate(in: f.first)
        try await finish(f, reference: john, alternate: true)
        XCTAssertEqual(f.live.source?.tabID, f.first.tabID, "A pending request has not taken ownership yet")
        XCTAssertTrue(f.live.isProjecting)
        try await finish(f, reference: romans, text: "New tab wins")
        try await eventually { f.live.source?.tabID == f.second.tabID }
        f.live.refreshPreferences()
        XCTAssertEqual(f.live.projector.projectorViewData.primaryText, "New tab wins")
        XCTAssertEqual(f.live.source?.sources.primary, f.primary)
        let staleRefresh = await f.alternateReader.waiting(john, lookup: true)
        XCTAssertFalse(staleRefresh)
    }

    func testDeferredSourceRefreshResumesWhenAnotherTabsSubmissionFailsOrIsCanceled() async throws {
        for cancel in [false, true] {
            let f = try Fixture(); defer { f.cleanUp() }
            f.first.navigate(to: john, project: true)
            try await finish(f, reference: john)
            try await eventually { f.live.windowOpened }
            f.second.navigate(to: romans, project: true)
            try await eventually { await f.reader.waiting(self.romans, lookup: false) }
            f.useAlternate(in: f.first)
            try await finish(f, reference: john, alternate: true)
            if cancel { f.second.browse("Genesis") }
            try await finish(f, reference: romans, available: false)
            try await finish(f, reference: john, lookup: true, alternate: true, text: "Deferred NLT refresh")
            try await eventually { f.live.projector.projectorViewData.primaryText == "Deferred NLT refresh" }
            XCTAssertEqual(f.live.source?.tabID, f.first.tabID)
            XCTAssertEqual(f.live.projector.projectionOwner?.reference, john)
            XCTAssertFalse(f.live.isProjecting)
        }
    }

    func testNewProjectionSupersedesSourceRefreshEvenWhenOldLookupCompletesLate() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        f.useAlternate(in: f.first)
        try await finish(f, reference: john, alternate: true)
        try await eventually { await f.alternateReader.waiting(self.john, lookup: true) }
        f.second.navigate(to: romans, project: true)
        try await finish(f, reference: romans, text: "New source tab")
        try await eventually { f.live.source?.tabID == f.second.tabID }
        await f.alternateReader.finish(john, lookup: true, text: "Stale refresh")
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(f.live.projector.projectorViewData.primaryText, "New source tab")
        XCTAssertEqual(f.live.source?.tabID, f.second.tabID)
    }

    func testDeferredTranslationRefreshPreservesFailedSearchProjectionError() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        f.live.requestProjection(owner: .searchResult(romans), from: f.second.tabID, sources: f.second.sources, using: f.second.navigation)
        try await eventually { await f.reader.waiting(self.romans, lookup: true) }
        f.useAlternate(in: f.first)
        try await finish(f, reference: john, alternate: true)
        try await finish(f, reference: romans, lookup: true, available: false)
        try await eventually { f.live.message != nil }
        let message = f.live.message
        try await finish(f, reference: john, lookup: true, alternate: true, text: "Refreshed live verse")
        try await eventually { f.live.projector.projectorViewData.primaryText == "Refreshed live verse" }
        XCTAssertEqual(f.live.source?.tabID, f.first.tabID)
        XCTAssertEqual(f.live.message, message, "Automatic refresh must preserve the failed explicit request's explanation")
    }

    func testChangingOwnTranslationsCancelsPendingSubmissionAndRejectsOldText() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await eventually { await f.reader.waiting(self.john, lookup: false) }
        f.useAlternate(in: f.first)
        try await finish(f, reference: john, alternate: true)
        await f.reader.finish(john, text: "Old translation")
        try await eventually { !f.first.navigation.isLoading }
        XCTAssertEqual(f.first.navigation.navigation.chapter?.sources, f.first.sources)
        XCTAssertNil(f.live.projector.projectionOwner)
        XCTAssertNil(f.live.source)
        XCTAssertEqual(f.opens, 0)
    }

    func testClosingSourceTabFreezesItsOutputAcrossOtherTranslationChanges() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        let revision = f.live.projector.revision
        f.first.shutdown()
        f.useAlternate(in: f.second)
        f.live.defaults.set(f.alternate.absoluteString, forKey: AppDefaultsKey.primaryBibleName)
        f.live.refreshPreferences()
        XCTAssertTrue(f.live.windowOpened)
        XCTAssertNil(f.live.source?.tabID)
        XCTAssertEqual(f.live.source?.sources.primary, f.primary)
        XCTAssertEqual(f.live.projector.revision, revision)
        XCTAssertFalse(f.live.isProjecting)
    }

    func testUnavailableSourceTabRefreshStopsOutput() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        f.useAlternate(in: f.first)
        f.first.shutdown()
        try await finish(f, reference: john, lookup: true, alternate: true, available: false)
        try await eventually { !f.live.windowOpened }
        XCTAssertNil(f.live.projector.projectionOwner)
        XCTAssertNotNil(f.live.message, "An automatic stop must explain the unavailable translation")
        f.second.dismissProjectionMessage(nil)
        XCTAssertNil(f.live.message)
    }

    func testFailedSubmissionSettlesWithoutPublishingOrRecordingHistory() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true, recordHistory: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        let history = f.first.history.entries
        let revision = f.live.projector.revision
        f.first.navigate(to: romans, project: true, recordHistory: true)
        try await finish(f, reference: romans, available: false)
        try await eventually { !f.first.navigation.isLoading && !f.live.isProjecting }
        XCTAssertEqual(f.live.projector.revision, revision)
        XCTAssertEqual(f.live.projector.projectionOwner?.reference, john)
        XCTAssertEqual(f.first.history.entries, history)
        XCTAssertNotNil(f.first.navigation.message)
    }

    func testSharedProjectionErrorCanBeDismissedOrClearedByExplicitStop() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        _ = f.first.view
        _ = f.second.view
        for dismiss in [true, false] {
            f.live.requestProjection(owner: .searchResult(romans), from: f.first.tabID, sources: f.first.sources, using: f.first.navigation)
            try await finish(f, reference: romans, lookup: true, available: false)
            try await eventually { f.live.message != nil }
            XCTAssertNil(f.first.navigation.message, "The source tab must not retain another copy of the shared error")
            f.first.render(); f.second.render()
            XCTAssertFalse(f.first.dismissProjectionMessageButton.isHidden)
            XCTAssertEqual(f.first.messageLabel.stringValue, f.second.messageLabel.stringValue)
            if dismiss { f.second.dismissProjectionMessage(nil) }
            else { f.second.stopProjection(nil) }
            f.first.render(); f.second.render()
            XCTAssertNil(f.live.message)
            XCTAssertTrue(f.first.footer.isHidden)
            XCTAssertTrue(f.second.footer.isHidden)
        }
    }

    func testDeferredCloseClearsOldOutputWhilePreservingNewPendingRequest() async throws {
        let f = try Fixture(); defer { f.cleanUp() }
        f.first.navigate(to: john, project: true)
        try await finish(f, reference: john)
        try await eventually { f.live.windowOpened }
        f.first.closeProjector()
        f.live.requestProjection(owner: .searchResult(psalm), from: f.second.tabID, sources: f.second.sources, using: f.second.navigation)
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
        f.live.publishRow(row, from: f.first.tabID)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(f.live.projector.projectionOwner?.reference, john)
        XCTAssertTrue(f.live.windowOpened)
    }
}
