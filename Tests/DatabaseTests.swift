import XCTest
import SQLite3
@testable import ViewTheWordCore

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ViewTheWordTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func executeSQL(_ sql: String, at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw BibleError.database("Test fixture open failed") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw BibleError.database(String(cString: sqlite3_errmsg(db)))
    }
}

func canonicalFixture(at url: URL) throws {
    // No id column, arbitrary column order, and an unrelated extra column.
    var sql = "CREATE TABLE bible(verse TEXT, vnumber INTEGER, extra TEXT, bnumber INTEGER, cnumber INTEGER); CREATE TABLE bnames(name TEXT); BEGIN;"
    for metadata in bibleBookMetadata {
        sql += "INSERT INTO bnames VALUES ('book');"
        for chapter in 1...metadata.chapters {
            sql += "INSERT INTO bible(verse,vnumber,bnumber,cnumber) VALUES ('fixture text',1,\(metadata.number),\(chapter));"
        }
    }
    sql += "INSERT INTO bible(verse,vnumber,bnumber,cnumber) VALUES ('JESUS: loves 100% of a_b.',16,43,3); COMMIT;"
    try executeSQL(sql, at: url)
}

final class DatabaseTests: XCTestCase {
    func testImportReadsNamedColumnsWithoutIDAndCreatesIndex() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ENG_TST.bible")
        try canonicalFixture(at: source)
        let destination = try await BibleImportService().importBible(selectedFile: source, bundledBibleNames: [], destinationDirectory: root.appendingPathComponent("library"))
        let reader = Bible(dbUrl: destination)
        let reference = VerseReference(book: "John", chapter: 3, verse: 16)!
        let verses = try await reader.verses([reference])
        XCTAssertEqual(verses.first?.verse, "JESUS: loves 100% of a_b.")
        let words = TextSearchRequest(text: "jesus", filter: .all, kind: .words(.term("jesus")))
        let matches = try await reader.search(words, after: nil, limit: 100)
        XCTAssertEqual(matches.first?.reference, reference)
        XCTAssertEqual(matches.first?.verse, verses.first?.verse)
        for literal in ["%", "_", "100%", "a_b"] {
            let request = TextSearchRequest(text: literal, filter: .all, kind: .phrase(literal))
            let results = try await reader.search(request, after: nil, limit: 100)
            XCTAssertEqual(results.map(\.reference), [reference], literal)
        }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(destination.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN SELECT verse FROM bible WHERE bnumber=43 AND cnumber=3 AND vnumber=16", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertTrue(String(cString: sqlite3_column_text(statement, 3)).contains("vtw_verse_coordinates"))
    }

    func testInvalidReplacementPreservesExistingImport() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ENG_TST.bible")
        try canonicalFixture(at: source)
        let service = BibleImportService()
        let directory = root.appendingPathComponent("library")
        let destination = try await service.importBible(selectedFile: source, bundledBibleNames: [], destinationDirectory: directory)
        let original = try Data(contentsOf: destination)
        try executeSQL("INSERT INTO bible SELECT * FROM bible LIMIT 1", at: source)
        do {
            _ = try await service.importBible(selectedFile: source, bundledBibleNames: [], destinationDirectory: directory, replaceExisting: true)
            XCTFail("Duplicate coordinates must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("duplicate")) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["ENG_TST.bible"])
    }

    func testInvalidCoordinateTypesAreRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, mutation) in ["vnumber = -1", "vnumber = 2147483648", "vnumber = 'bad'", "verse = NULL"].enumerated() {
            let folder = root.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("ENG_TST.bible")
            try canonicalFixture(at: source)
            try executeSQL("UPDATE bible SET \(mutation) WHERE bnumber=43 AND cnumber=3 AND vnumber=16", at: source)
            do {
                _ = try await BibleImportService().importBible(selectedFile: source, bundledBibleNames: [], destinationDirectory: folder.appendingPathComponent("library"))
                XCTFail("Accepted \(mutation)")
            } catch { XCTAssertTrue(error is BibleImportError) }
        }
    }

    func testCommittedWALIsIncludedAndSuccessfulReplacementIsReadable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ENG_TST.bible")
        try canonicalFixture(at: source)
        let service = BibleImportService()
        let directory = root.appendingPathComponent("library")
        _ = try await service.importBible(selectedFile: source, bundledBibleNames: [], destinationDirectory: directory)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE bible SET verse='committed WAL replacement' WHERE bnumber=43 AND cnumber=3 AND vnumber=16", nil, nil, nil), SQLITE_OK)
        let destination = try await service.importBible(selectedFile: source, bundledBibleNames: [], destinationDirectory: directory, replaceExisting: true)
        let verses = try await Bible(dbUrl: destination).verses([VerseReference(book: "John", chapter: 3, verse: 16)!])
        XCTAssertEqual(verses.first?.verse, "committed WAL replacement")
    }

    func testBundledDualLanguageMatchesAndPagination() async throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ViewTheWord/Resources")
        let primaryURL = resources.appendingPathComponent("MAL_BSI.bible"), secondaryURL = resources.appendingPathComponent("ENG_UKJV.bible")
        let primary = Bible(dbUrl: primaryURL), secondary = Bible(dbUrl: secondaryURL)
        let sources = BibleSources(primary: primaryURL, secondary: secondaryURL, revision: 0)
        let wordRequest = TextSearchRequest(text: "jesus", filter: .all, kind: .words(.term("jesus")))
        let page = try await VerseTargetModel.loadSearchPage(wordRequest, sources: sources, primary: primary, secondary: secondary)
        XCTAssertEqual(page.hits.count, 100)
        XCTAssertTrue(page.hasMore)
        XCTAssertTrue(page.hits.allSatisfy { !$0.matchedPrimary && $0.matchedSecondary && $0.pair.primary != nil && $0.pair.secondary != nil })
        XCTAssertTrue(page.hits.contains { $0.pair.reference == VerseReference(book: "Matthew", chapter: 1, verse: 21) })
        let request = TextSearchRequest(text: "love", filter: .all, kind: .phrase("love"))
        let all = try await secondary.search(request, after: nil, limit: 10_000)
        var ids: [VerseCoordinate] = [], cursor: VerseCoordinate?
        repeat {
            let next = try await VerseTargetModel.loadSearchPage(request, sources: sources, primary: primary, secondary: secondary, after: cursor)
            ids += next.hits.map(\.id)
            cursor = next.cursor
            if !next.hasMore { break }
            XCTAssertNotNil(cursor)
            if ids.count > 10_000 { XCTFail("Pagination did not finish"); break }
        } while true
        XCTAssertGreaterThan(ids.count, 100)
        XCTAssertEqual(ids, all.map(\.id))
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDatabaseFailureIsDistinctFromAnEmptyResult() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await Bible(dbUrl: root.appendingPathComponent("missing.bible")).chapter(VerseReference(book: "John", chapter: 3, verse: 16)!)
            XCTFail("Missing database should throw")
        } catch { XCTAssertTrue(error is BibleError) }
    }
}
