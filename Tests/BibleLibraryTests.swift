import XCTest
@testable import ViewTheWordCore

private actor SuspendedImporter {
    struct Call: Equatable {
        let url: URL
        let replaceExisting: Bool
    }
    private(set) var calls: [Call] = []
    private var pending: CheckedContinuation<URL, Error>?
    private var waiter: CheckedContinuation<Void, Never>?

    func run(_ url: URL, replaceExisting: Bool) async throws -> URL {
        precondition(pending == nil, "Imports must run serially")
        calls.append(Call(url: url, replaceExisting: replaceExisting))
        return try await withCheckedThrowingContinuation {
            pending = $0
            waiter?.resume()
            waiter = nil
        }
    }
    func waitForImport() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish(_ result: Result<URL, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

@MainActor
final class BibleLibraryTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/fixtures/ENG_\(name).bible") }
    private func library(_ importer: SuspendedImporter) -> BibleLibrary {
        BibleLibrary(preloadedURLs: [], importer: { url, _, replaceExisting in
            try await importer.run(url, replaceExisting: replaceExisting)
        })
    }
    private func settle(_ subject: BibleLibrary) async throws {
        for _ in 0..<200 {
            if !subject.isImporting { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Import did not finish")
    }

    func testEveryIncomingFileIsImportedAndEveryResultKeepsItsPresenter() async throws {
        let importer = SuspendedImporter()
        let subject = library(importer)
        let first = url("FIRST"), invalid = url("INVALID"), later = url("LATER")
        subject.importFile(first, presenter: .main)
        subject.importFile(invalid, presenter: .main)
        await importer.waitForImport()
        // A second open request arrives while the first batch is still running.
        subject.importFile(later, presenter: .settings)
        await importer.finish(.success(first))
        await importer.waitForImport()
        await importer.finish(.failure(CocoaError(.fileReadCorruptFile)))
        await importer.waitForImport()
        await importer.finish(.success(later))
        try await settle(subject)
        let calls = await importer.calls
        XCTAssertEqual(calls.map(\.url), [first, invalid, later])
        XCTAssertTrue(calls.allSatisfy { !$0.replaceExisting })
        XCTAssertEqual(Set(subject.urls), [first, later])

        let firstAlert = try XCTUnwrap(subject.claimAlert(for: .main))
        XCTAssertTrue(firstAlert.message.contains("FIRST"))
        XCTAssertNil(subject.claimAlert(for: .main), "Another tab cannot claim the same prompt")
        subject.completeAlert(firstAlert.id)
        let failure = try XCTUnwrap(subject.claimAlert(for: .main))
        XCTAssertTrue(failure.message.contains("ENG_INVALID.bible"))
        subject.completeAlert(firstAlert.id)
        XCTAssertEqual(subject.alert(for: .main)?.id, failure.id, "A stale dismissal cannot consume the next alert")
        subject.completeAlert(failure.id)
        XCTAssertNil(subject.claimAlert(for: .main))
        let lastAlert = try XCTUnwrap(subject.claimAlert(for: .settings))
        XCTAssertTrue(lastAlert.message.contains("LATER"))
        subject.completeAlert(lastAlert.id)
        XCTAssertTrue(subject.alerts.isEmpty)
    }

    func testReplacementDecisionRetainsLaterFilesAndRequiresExplicitConsent() async throws {
        for replace in [false, true] {
            let importer = SuspendedImporter()
            let subject = library(importer)
            let existing = url("EXISTING"), next = url("NEXT"), later = url("LATER")
            subject.importFile(existing, presenter: .main)
            subject.importFile(next, presenter: .main)
            await importer.waitForImport()
            await importer.finish(.failure(BibleImportError.bibleAlreadyExists(existing.lastPathComponent)))
            try await settle(subject)
            let prompt = try XCTUnwrap(subject.claimAlert(for: .main))
            XCTAssertEqual(prompt.content, .replacement(existing))
            subject.importFile(later, presenter: .main)
            try await Task.sleep(nanoseconds: 20_000_000)
            let waitingCalls = await importer.calls
            XCTAssertEqual(waitingCalls.count, 1, "Claiming a prompt is not a replacement decision")
            XCTAssertNil(subject.claimAlert(for: .main))
            subject.completeAlert(prompt.id, replaceExisting: replace)
            await importer.waitForImport()
            if replace {
                let retry = await importer.calls.last
                XCTAssertEqual(retry, SuspendedImporter.Call(url: existing, replaceExisting: true))
                // Even a failed replacement must release the rest of the queue.
                await importer.finish(.failure(CocoaError(.fileWriteNoPermission)))
                await importer.waitForImport()
            }
            await importer.finish(.success(next))
            await importer.waitForImport()
            await importer.finish(.success(later))
            try await settle(subject)
            let calls = await importer.calls
            XCTAssertEqual(calls.map(\.url), replace ? [existing, existing, next, later] : [existing, next, later])
            XCTAssertEqual(Set(subject.urls), [next, later])
            while let alert = subject.alerts.first { subject.completeAlert(alert.id) }
        }
    }

    func testHiddenSettingsNoticeDoesNotBlockFinderReplacement() async throws {
        let importer = SuspendedImporter()
        let subject = library(importer)
        subject.showNotice("Earlier Settings result", presenter: .settings)
        subject.importFile(url("EXISTING"), presenter: .main)
        await importer.waitForImport()
        await importer.finish(.failure(BibleImportError.bibleAlreadyExists("ENG_EXISTING.bible")))
        try await settle(subject)
        let prompt = try XCTUnwrap(subject.claimAlert(for: .main))
        XCTAssertEqual(prompt.content, .replacement(url("EXISTING")))
        subject.completeAlert(prompt.id)
        XCTAssertNil(subject.alert(for: .main))
        XCTAssertEqual(subject.alert(for: .settings)?.message, "Earlier Settings result")
    }
}
