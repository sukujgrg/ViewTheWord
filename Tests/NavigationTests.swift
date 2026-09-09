import XCTest
@testable import ViewTheWordCore

private func verse(_ chapter: Int, _ number: Int = 1, book: String = "John", text: String? = nil) -> AVerse {
    AVerse(reference: VerseReference(book: book, chapter: chapter, verse: number)!, verse: text ?? "\(book) \(chapter):\(number) text")
}

private struct MemoryBible: BibleReading {
    let rows: [AVerse]
    func chapter(_ reference: VerseReference) async throws -> [AVerse] { rows.filter { $0.bookName == reference.book && $0.chapterNumber == reference.chapter } }
    func verses(_ references: [VerseReference]) async throws -> [AVerse] { rows.filter { references.contains($0.reference) } }
    func search(_ request: TextSearchRequest, after: VerseCoordinate?, limit: Int) async throws -> [AVerse] { [] }
}

/// Deliberately ignores task cancellation to exercise the generation checks, not just cooperative cancellation.
private actor SuspendedBible: BibleReading {
    private var chapters: [VerseReference: CheckedContinuation<[AVerse], Error>] = [:]
    private var lookups: [VerseReference: CheckedContinuation<[AVerse], Error>] = [:]
    private var chapterWaiters: [VerseReference: CheckedContinuation<Void, Never>] = [:]
    private var lookupWaiters: [VerseReference: CheckedContinuation<Void, Never>] = [:]

    func chapter(_ reference: VerseReference) async throws -> [AVerse] {
        try await withCheckedThrowingContinuation {
            chapters[reference] = $0
            chapterWaiters.removeValue(forKey: reference)?.resume()
        }
    }
    func verses(_ references: [VerseReference]) async throws -> [AVerse] {
        guard let reference = references.first else { return [] }
        return try await withCheckedThrowingContinuation {
            lookups[reference] = $0
            lookupWaiters.removeValue(forKey: reference)?.resume()
        }
    }
    func search(_ request: TextSearchRequest, after: VerseCoordinate?, limit: Int) async throws -> [AVerse] { [] }
    func waitForChapter(_ reference: VerseReference) async {
        if chapters[reference] != nil { return }
        await withCheckedContinuation { chapterWaiters[reference] = $0 }
    }
    func waitForLookup(_ reference: VerseReference) async {
        if lookups[reference] != nil { return }
        await withCheckedContinuation { lookupWaiters[reference] = $0 }
    }
    func finishChapter(_ reference: VerseReference, rows: [AVerse]) { chapters.removeValue(forKey: reference)?.resume(returning: rows) }
    func finishLookup(_ reference: VerseReference, rows: [AVerse]) { lookups.removeValue(forKey: reference)?.resume(returning: rows) }
}

@MainActor
final class NavigationTests: XCTestCase {
    private let primaryURL = URL(fileURLWithPath: "/primary/ENG_TST.bible")
    private let secondaryURL = URL(fileURLWithPath: "/secondary/MAL_TST.bible")
    private var sources: BibleSources { BibleSources(primary: primaryURL, secondary: nil, revision: 1) }

    func testChapterCommitsAtomicallyAndOlderCompletionCannotOverwrite() async throws {
        let reader = SuspendedBible()
        let model = VerseTargetModel(readerFactory: { _ in reader })
        let john3 = verse(3).reference, john4 = verse(4).reference
        let oldCompletion = expectation(description: "old navigation must be discarded")
        oldCompletion.isInverted = true
        model.navigate(to: john3, sources: sources) { _ in oldCompletion.fulfill() }
        await reader.waitForChapter(john3)
        XCTAssertNil(model.navigation.chapter)
        let completed = expectation(description: "new chapter committed")
        model.navigate(to: john4, sources: sources) { _ in completed.fulfill() }
        await reader.waitForChapter(john4)
        XCTAssertNil(model.navigation.chapter)
        await reader.finishChapter(john4, rows: [verse(4), verse(4, 2)])
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(model.verseQuery.chapterNumber, 4)
        XCTAssertEqual(model.verseRowData.primaryChapter.map(\.chapterNumber), [4, 4])
        XCTAssertNil(model.prepareRowProjection(verse(3, 2).reference, sources: sources))
        XCTAssertEqual(model.prepareRowProjection(verse(4, 2).reference, sources: sources)?.data.primaryText, "John 4:2 text")
        await reader.finishChapter(john3, rows: [verse(3)])
        await fulfillment(of: [oldCompletion], timeout: 0.05)
        XCTAssertEqual(model.verseQuery.chapterNumber, 4)
    }

    func testEscapeInvalidatesPendingSearchProjection() async {
        let reader = SuspendedBible()
        let model = VerseTargetModel(readerFactory: { _ in reader })
        let reference = verse(3, 16).reference
        let completion = expectation(description: "closed projection must not reopen")
        completion.isInverted = true
        model.requestProjection(owner: .searchResult(reference), sources: sources) { _ in completion.fulfill() }
        await reader.waitForLookup(reference)
        model.cancelProjection()
        await reader.finishLookup(reference, rows: [verse(3, 16)])
        await fulfillment(of: [completion], timeout: 0.05)
        XCTAssertFalse(model.isProjecting)
    }

    func testEscapeStillAllowsNavigationButSuppressesItsProjection() async {
        let reader = SuspendedBible()
        let model = VerseTargetModel(readerFactory: { _ in reader })
        let reference = verse(3, 16).reference
        let completed = expectation(description: "navigation finishes without projection")
        model.navigate(to: reference, sources: sources, project: true) { result in
            XCTAssertNil(result.projection)
            XCTAssertTrue(result.requestedAvailable)
            completed.fulfill()
        }
        await reader.waitForChapter(reference)
        model.cancelProjection()
        await reader.finishChapter(reference, rows: [verse(3, 16)])
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(model.verseQuery, reference.verseQuery)
    }

    func testNewerProjectionSupersedesOlderRequest() async {
        let reader = SuspendedBible()
        let model = VerseTargetModel(readerFactory: { _ in reader })
        let old = verse(3, 16), new = verse(3, 17)
        let discarded = expectation(description: "old projection discarded"); discarded.isInverted = true
        model.requestProjection(owner: .searchResult(old.reference), sources: sources) { _ in discarded.fulfill() }
        await reader.waitForLookup(old.reference)
        let completed = expectation(description: "new projection ready")
        model.requestProjection(owner: .searchResult(new.reference), sources: sources) { projection in
            XCTAssertEqual(projection?.owner.reference, new.reference)
            completed.fulfill()
        }
        await reader.waitForLookup(new.reference)
        await reader.finishLookup(new.reference, rows: [new])
        await fulfillment(of: [completed], timeout: 1)
        await reader.finishLookup(old.reference, rows: [old])
        await fulfillment(of: [discarded], timeout: 0.05)
    }

    func testPrimaryOnlyRefreshDropsMissingSecondaryVerseAndUsesValidFallback() async {
        let primary = MemoryBible(rows: [verse(1, 14, book: "3 John")])
        let secondary = MemoryBible(rows: [verse(1, 14, book: "3 John"), verse(1, 15, book: "3 John")])
        let firstURL = primaryURL
        let model = VerseTargetModel(readerFactory: { $0 == firstURL ? primary : secondary })
        let reference = verse(1, 15, book: "3 John").reference
        let dual = BibleSources(primary: primaryURL, secondary: secondaryURL, revision: 1)
        let loaded = expectation(description: "dual chapter")
        model.navigate(to: reference, sources: dual) { _ in loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 1)
        XCTAssertEqual(model.verseQuery.verseNumber, 15)
        let refreshed = expectation(description: "primary-only chapter")
        model.navigate(to: reference, sources: sources) { result in
            XCTAssertFalse(result.requestedAvailable)
            XCTAssertEqual(result.reference.verse, 14)
            refreshed.fulfill()
        }
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertTrue(model.verseRowData.secondaryChapter.isEmpty)
        XCTAssertNil(model.prepareRowProjection(reference, sources: sources))
        XCTAssertEqual(model.navigation.chapter?.rows.count, 1)
        let unavailable = expectation(description: "live missing verse unavailable")
        model.requestProjection(owner: .searchResult(reference), sources: sources) { projection in
            XCTAssertNil(projection); unavailable.fulfill()
        }
        await fulfillment(of: [unavailable], timeout: 1)
    }

    func testBrowsingAndTranslationRefreshKeepTheLiveReference() async {
        let reader = MemoryBible(rows: [verse(3, 16), verse(8, book: "Romans")])
        let model = VerseTargetModel(readerFactory: { _ in reader })
        let projector = ProjectorViewModel()
        let live = verse(3, 16).reference
        let initial = expectation(description: "initial projection")
        model.navigate(to: live, sources: sources, project: true) { result in
            if let projection = result.projection { projector.project(projection.data, owner: projection.owner) }
            initial.fulfill()
        }
        await fulfillment(of: [initial], timeout: 1)
        let browsed = expectation(description: "browse other chapter")
        model.navigate(to: verse(8, book: "Romans").reference, sources: sources) { result in
            XCTAssertNil(result.projection); browsed.fulfill()
        }
        await fulfillment(of: [browsed], timeout: 1)
        projector.toggleBlank()
        let refresh = expectation(description: "refresh live owner")
        model.requestProjection(owner: projector.projectionOwner!, sources: sources) { projection in
            if let projection { projector.project(projection.data, owner: projection.owner, preserveBlanking: true) }
            refresh.fulfill()
        }
        await fulfillment(of: [refresh], timeout: 1)
        XCTAssertEqual(model.verseQuery.bookName, "Romans")
        XCTAssertEqual(projector.projectionOwner?.reference, live)
        XCTAssertTrue(projector.isBlanked)
    }

    func testSameChapterNumberInAnotherBookLoadsThatBook() async {
        let reader = MemoryBible(rows: [verse(3), verse(3, book: "Romans")])
        let model = VerseTargetModel(readerFactory: { _ in reader })
        for book in ["John", "Romans"] {
            let completed = expectation(description: "Load \(book) 3")
            model.navigate(to: verse(3, book: book).reference, sources: sources) { _ in completed.fulfill() }
            await fulfillment(of: [completed], timeout: 1)
            XCTAssertEqual(model.verseQuery.bookName, book)
            XCTAssertEqual(model.verseRowData.primaryChapter.first?.verse, "\(book) 3:1 text")
        }
    }

    func testBrowsingDoesNotCancelIndependentLiveRefresh() async {
        let reader = SuspendedBible()
        let model = VerseTargetModel(readerFactory: { _ in reader })
        let live = verse(3, 16).reference, browsing = verse(4).reference
        let refreshed = expectation(description: "Live reference refresh survives browsing")
        model.requestProjection(owner: .searchResult(live), sources: sources) { projection in
            XCTAssertEqual(projection?.owner.reference, live)
            refreshed.fulfill()
        }
        await reader.waitForLookup(live)
        let loaded = expectation(description: "Browse another chapter")
        model.navigate(to: browsing, sources: sources) { _ in loaded.fulfill() }
        await reader.waitForChapter(browsing)
        await reader.finishChapter(browsing, rows: [verse(4)])
        await fulfillment(of: [loaded], timeout: 1)
        XCTAssertTrue(model.isProjecting)
        await reader.finishLookup(live, rows: [verse(3, 16)])
        await fulfillment(of: [refreshed], timeout: 1)
    }

    func testTextSearchCancelsSupersededNavigationProjection() async {
        let reader = SuspendedBible()
        let model = VerseTargetModel(readerFactory: { _ in reader })
        let reference = verse(3, 16).reference
        let discarded = expectation(description: "Superseded verse submission"); discarded.isInverted = true
        model.navigate(to: reference, sources: sources, project: true) { _ in discarded.fulfill() }
        await reader.waitForChapter(reference)
        let completed = expectation(description: "Text search finishes")
        model.search(TextSearchRequest(text: "love", filter: .all, kind: .phrase("love")), sources: sources) { completed.fulfill() }
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertFalse(model.isProjecting)
        await reader.finishChapter(reference, rows: [verse(3, 16)])
        await fulfillment(of: [discarded], timeout: 0.05)
    }

    func testDeferredCloseCleanupPreservesNewPendingProjection() async {
        let reader = SuspendedBible()
        let model = VerseTargetModel(readerFactory: { _ in reader })
        let old = verse(3, 16), new = verse(3, 17)
        let discarded = expectation(description: "Closed request stays canceled"); discarded.isInverted = true
        model.requestProjection(owner: .searchResult(old.reference), sources: sources) { _ in discarded.fulfill() }
        await reader.waitForLookup(old.reference)
        let cancellationID = model.cancelProjection(updateStatus: false)
        let completed = expectation(description: "New request survives deferred cleanup")
        model.requestProjection(owner: .searchResult(new.reference), sources: sources) { result in
            XCTAssertEqual(result?.owner.reference, new.reference)
            completed.fulfill()
        }
        await reader.waitForLookup(new.reference)
        model.finishProjectionCancellation(cancellationID)
        XCTAssertTrue(model.isProjecting)
        await reader.finishLookup(new.reference, rows: [new])
        await reader.finishLookup(old.reference, rows: [old])
        await fulfillment(of: [completed, discarded], timeout: 0.1)
    }

    func testLoadedChapterRejectsMismatchedOrDuplicateCoordinates() {
        XCTAssertThrowsError(try LoadedChapter(reference: verse(4).reference, sources: sources, primary: [verse(3)], secondary: []))
        XCTAssertThrowsError(try LoadedChapter(reference: verse(3).reference, sources: sources, primary: [verse(3), verse(3)], secondary: []))
    }
}
