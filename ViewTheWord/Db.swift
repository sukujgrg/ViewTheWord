import Foundation
import SQLite3

struct AVerse: Identifiable {
    var id: Int { verseId }

    let verseId: Int
    let bookNumber: Int
    let bookName: String
    let chapterNumber: Int
    let verseNumber: Int
    let verse: String
}

class BibleUrl {
    private static let cacheQueue = DispatchQueue(label: "com.viewtheword.bibleurl.cache")
    private static var cachedAvailableBibleUrls: [URL]?

    var primaryBibleUrl: URL
    var secondaryBibleUrl: URL

    static func invalidateAvailableBibleUrlCache() {
        cacheQueue.sync {
            cachedAvailableBibleUrls = nil
        }
    }

    init() {
        primaryBibleUrl = bundledPrimaryBibleUrl ?? URL(fileURLWithPath: "/dev/null")
        secondaryBibleUrl = bundledSecondaryBibleUrl ?? primaryBibleUrl

        let availableBibleUrls = getAvailableBibleUrls()

        let fallbackURL = availableBibleUrls.first ?? URL(fileURLWithPath: "/dev/null")
        if fallbackURL.path == "/dev/null" {
            logger.fault("No Bible files are available; using /dev/null as a non-crashing placeholder.")
        }

        if let primary = getBibleUrl(defaultsKey: AppDefaultsKey.primaryBibleName) {
            primaryBibleUrl = primary
        } else if let bundledPrimary = bundledPrimaryBibleUrl {
            primaryBibleUrl = bundledPrimary
        } else if let firstAvailable = availableBibleUrls.first {
            logger.warning("Bundled primary Bible missing; falling back to \(firstAvailable.lastPathComponent).")
            primaryBibleUrl = firstAvailable
        } else {
            primaryBibleUrl = fallbackURL
        }

        if let secondary = getBibleUrl(defaultsKey: AppDefaultsKey.secondaryBibleName) {
            secondaryBibleUrl = secondary
        } else if let bundledSecondary = bundledSecondaryBibleUrl {
            secondaryBibleUrl = bundledSecondary
        } else if let secondaryFallback = availableBibleUrls.first(where: { $0 != primaryBibleUrl }) {
            logger.warning("Bundled secondary Bible missing; falling back to \(secondaryFallback.lastPathComponent).")
            secondaryBibleUrl = secondaryFallback
        } else {
            secondaryBibleUrl = primaryBibleUrl
        }
    }

    func getBibleUrl(defaultsKey: String) -> URL? {
        let availableBibleUrls = getAvailableBibleUrls()

        let defaults = UserDefaults.standard

        if let bibleName = defaults.string(forKey: defaultsKey), !bibleName.isEmpty {
            let storedLastPath = URL(string: bibleName)?.lastPathComponent
                ?? URL(fileURLWithPath: bibleName).lastPathComponent

            for url in availableBibleUrls where url.lastPathComponent == storedLastPath {
                return url
            }
        }
        return nil
    }

    func getAvailableBibleUrls(forceRefresh: Bool = false) -> [URL] {
        if !forceRefresh {
            let cachedUrls = Self.cacheQueue.sync { Self.cachedAvailableBibleUrls }
            if let cachedUrls {
                return cachedUrls
            }
        }

        let scannedUrls = scanAvailableBibleUrls()
        Self.cacheQueue.sync {
            Self.cachedAvailableBibleUrls = scannedUrls
        }
        return scannedUrls
    }

    private func scanAvailableBibleUrls() -> [URL] {
        var availableBibleUrls: [URL] = []

        if let primary = bundledPrimaryBibleUrl {
            availableBibleUrls.append(primary)
        }
        if let secondary = bundledSecondaryBibleUrl {
            availableBibleUrls.append(secondary)
        }

        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.error("Could not access documents directory")
            return availableBibleUrls
        }

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            let bibleDbUrls = fileURLs.filter {
                $0.pathExtension.lowercased() == BibleFileRule.fileExtension
                    && BibleFileRule.isValidFileName($0.lastPathComponent)
            }
            availableBibleUrls += bibleDbUrls
        } catch {
            logger.error("\(documentsURL.path): \(error.localizedDescription)")
        }
        var dedupedByFileName: [String: URL] = [:]
        for url in availableBibleUrls {
            dedupedByFileName[url.lastPathComponent] = url
        }

        return Array(dedupedByFileName.values)
    }
}

final class Bible: @unchecked Sendable {
    let dbUrl: URL
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.viewtheword.database", qos: .userInitiated)
    private var pickVerseStatement: OpaquePointer?
    private var pickChapterStatement: OpaquePointer?
    private var searchTextStatement: OpaquePointer?

    private let pickVerseQuery = """
        SELECT id, bnumber, cnumber, vnumber, verse
        FROM bible
        WHERE bnumber = ? AND cnumber = ? AND vnumber = ?
        LIMIT 1;
    """

    private let pickChapterQuery = """
        SELECT id, bnumber, cnumber, vnumber, verse
        FROM bible
        WHERE bnumber = ? AND cnumber = ?
        ORDER BY vnumber;
    """

    private let searchTextQuery = """
        SELECT id, bnumber, cnumber, vnumber, verse
        FROM bible
        WHERE verse LIKE ?
        ORDER BY bnumber, cnumber, vnumber
        LIMIT ?;
    """

    // Cache for O(1) book number to name lookups
    internal static let bookNumberToName: [Int: String] = {
        var cache: [Int: String] = [:]
        for (name, details) in bibleBooks {
            cache[details[0]] = name
        }
        return cache
    }()

    init(dbUrl: URL) {
        self.dbUrl = dbUrl
        db = openDb()
    }

    deinit {
        self.closeDb()
    }

    func closeDb() {
        dbQueue.sync {
            finalizeStatement(&pickVerseStatement)
            finalizeStatement(&pickChapterStatement)
            finalizeStatement(&searchTextStatement)

            if let db = db, sqlite3_close_v2(db) != SQLITE_OK {
                logger.error("Error closing \(self.dbUrl.absoluteString).")
            }
            db = nil
        }
    }

    /// Get a single verse by book/chapter/verse coordinates
    func getVerse(bookNumber: Int, chapterNumber: Int, verseNumber: Int) -> AVerse? {
        return dbQueue.sync {
            guard let db = db else { return nil }

            let query = """
                SELECT id, bnumber, cnumber, vnumber, verse
                FROM bible
                WHERE bnumber = ? AND cnumber = ? AND vnumber = ?
                LIMIT 1;
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                return nil
            }

            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int(statement, 1, Int32(bookNumber))
            sqlite3_bind_int(statement, 2, Int32(chapterNumber))
            sqlite3_bind_int(statement, 3, Int32(verseNumber))

            guard sqlite3_step(statement) == SQLITE_ROW else {
                return nil
            }

            let verseId = Int(sqlite3_column_int(statement, 0))
            let bnumber = Int(sqlite3_column_int(statement, 1))
            let cnumber = Int(sqlite3_column_int(statement, 2))
            let vnumber = Int(sqlite3_column_int(statement, 3))

            guard let verseText = sqlite3_column_text(statement, 4) else {
                return nil
            }

            let verse = String(cString: verseText)
            let bookName = Bible.bookNumberToName[bnumber] ?? "Unknown"

            return AVerse(
                verseId: verseId,
                bookNumber: bnumber,
                bookName: bookName,
                chapterNumber: cnumber,
                verseNumber: vnumber,
                verse: verse
            )
        }
    }

    func getVerses(for coordinates: [(bookNumber: Int, chapterNumber: Int, verseNumber: Int)]) -> [AVerse] {
        dbQueue.sync {
            getVersesUnlocked(for: coordinates)
        }
    }

    func getVersesAsync(for coordinates: [(bookNumber: Int, chapterNumber: Int, verseNumber: Int)]) async -> [AVerse] {
        await withCheckedContinuation { continuation in
            dbQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: self.getVersesUnlocked(for: coordinates))
            }
        }
    }

    func openDb() -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbUrl.path, &db, SQLite3.SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            logger.error("\(errmsg)")
            closeDb()
            return nil
        } else {
            return db
        }
    }
    func bookNumber(bookName: String) -> Int? {
        return bibleBooks[bookName]?.first
    }

    func getChapterCount(bookName: String) -> Int32? {
        dbQueue.sync {
            getChapterCountUnlocked(bookName: bookName)
        }
    }

    func getChapterCountAsync(bookName: String) async -> Int32? {
        await withCheckedContinuation { continuation in
            dbQueue.async { [weak self] in
                continuation.resume(returning: self?.getChapterCountUnlocked(bookName: bookName))
            }
        }
    }

    func pickAVerse(verseQuery: VerseQuery) -> AVerse? {
        dbQueue.sync {
            pickAVerseUnlocked(verseQuery: verseQuery)
        }
    }

    func pickAVerseAsync(verseQuery: VerseQuery) async -> AVerse? {
        await withCheckedContinuation { continuation in
            dbQueue.async { [weak self] in
                continuation.resume(returning: self?.pickAVerseUnlocked(verseQuery: verseQuery))
            }
        }
    }

    func pickAChapter(verseQuery: VerseQuery) -> [AVerse]? {
        dbQueue.sync {
            pickAChapterUnlocked(verseQuery: verseQuery)
        }
    }

    func pickAChapterAsync(verseQuery: VerseQuery) async -> [AVerse]? {
        await withCheckedContinuation { continuation in
            dbQueue.async { [weak self] in
                continuation.resume(returning: self?.pickAChapterUnlocked(verseQuery: verseQuery))
            }
        }
    }

    func searchText(searchQuery: String, limit: Int = 100) -> [AVerse]? {
        dbQueue.sync {
            searchTextUnlocked(searchQuery: searchQuery, limit: limit)
        }
    }

    func searchTextAsync(searchQuery: String, limit: Int = 100) async -> [AVerse]? {
        await withCheckedContinuation { continuation in
            dbQueue.async { [weak self] in
                continuation.resume(returning: self?.searchTextUnlocked(searchQuery: searchQuery, limit: limit))
            }
        }
    }

    func searchTextWithFilter(searchQuery: String, filter: SearchFilter, limit: Int = 100) -> [AVerse]? {
        dbQueue.sync {
            searchTextWithFilterUnlocked(searchQuery: searchQuery, filter: filter, limit: limit)
        }
    }

    func searchTextWithFilterAsync(searchQuery: String, filter: SearchFilter, limit: Int = 100) async -> [AVerse]? {
        await withCheckedContinuation { continuation in
            dbQueue.async { [weak self] in
                continuation.resume(returning: self?.searchTextWithFilterUnlocked(searchQuery: searchQuery, filter: filter, limit: limit))
            }
        }
    }

    func searchWithExpression(expression: SearchExpression, filter: SearchFilter, limit: Int = 100) -> [AVerse]? {
        dbQueue.sync {
            searchWithExpressionUnlocked(expression: expression, filter: filter, limit: limit)
        }
    }

    func searchWithExpressionAsync(expression: SearchExpression, filter: SearchFilter, limit: Int = 100) async -> [AVerse]? {
        let sql = expression.toSQL()
        let baseWhereClause = sql.whereClause
        let searchTerms = sql.terms
        let bookNumbers = filter.bookNumbers()

        return await withCheckedContinuation { continuation in
            dbQueue.async { [weak self] in
                continuation.resume(returning: self?.searchWithExpressionComponentsUnlocked(
                    baseWhereClause: baseWhereClause,
                    searchTerms: searchTerms,
                    bookNumbers: bookNumbers,
                    limit: limit
                ))
            }
        }
    }

    private func getChapterCountUnlocked(bookName: String) -> Int32? {
        guard let bookNumber = bookNumber(bookName: bookName) else {
            return nil
        }
        let q = "SELECT COUNT(DISTINCT cnumber) FROM bible WHERE bnumber = ?;"
        return runChapterCountQuery(queryStatementString: q, bookNumber: bookNumber)
    }

    private func pickAVerseUnlocked(verseQuery: VerseQuery) -> AVerse? {
        guard let bookNumber = bookNumber(bookName: verseQuery.bookName) else {
            return nil
        }

        guard let statement = cachedStatement(
            statement: &pickVerseStatement,
            query: pickVerseQuery,
            context: "pick verse query"
        ) else {
            return nil
        }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_int(statement, 1, Int32(bookNumber))
        sqlite3_bind_int(statement, 2, Int32(verseQuery.chapterNumber))
        sqlite3_bind_int(statement, 3, Int32(verseQuery.verseNumber))

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return makeVerse(from: statement, fallbackBookName: verseQuery.bookName)
    }

    private func pickAChapterUnlocked(verseQuery: VerseQuery) -> [AVerse]? {
        guard let bookNumber = bookNumber(bookName: verseQuery.bookName) else {
            return nil
        }

        guard let statement = cachedStatement(
            statement: &pickChapterStatement,
            query: pickChapterQuery,
            context: "pick chapter query"
        ) else {
            return nil
        }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_int(statement, 1, Int32(bookNumber))
        sqlite3_bind_int(statement, 2, Int32(verseQuery.chapterNumber))

        var verses: [AVerse] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let verse = makeVerse(from: statement, fallbackBookName: verseQuery.bookName) else {
                continue
            }
            verses.append(verse)
        }

        return verses.isEmpty ? nil : verses
    }

    private func searchTextUnlocked(searchQuery: String, limit: Int) -> [AVerse]? {
        guard let statement = cachedStatement(
            statement: &searchTextStatement,
            query: searchTextQuery,
            context: "search text query"
        ) else {
            return nil
        }

        let pattern = "%\(searchQuery)%"
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, (pattern as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var verses: [AVerse] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let verse = makeVerse(from: statement, fallbackBookName: nil) else {
                continue
            }
            verses.append(verse)
        }

        return verses.isEmpty ? nil : verses
    }

    private func searchTextWithFilterUnlocked(searchQuery: String, filter: SearchFilter, limit: Int) -> [AVerse]? {
        var whereClause = "verse LIKE ?"
        var bookNumbers: [Int]? = nil

        if let numbers = filter.bookNumbers() {
            bookNumbers = numbers
            let placeholders = numbers.map { _ in "?" }.joined(separator: ",")
            whereClause = "(\(whereClause)) AND bnumber IN (\(placeholders))"
        }

        let queryStatementString = """
            SELECT * FROM bible
                WHERE \(whereClause)
                ORDER BY bnumber, cnumber, vnumber
                LIMIT ?;
        """
        return runSearchQueryWithFilter(
            queryStatementString: queryStatementString,
            searchPattern: "%\(searchQuery)%",
            bookNumbers: bookNumbers,
            limit: limit
        )
    }

    private func searchWithExpressionUnlocked(expression: SearchExpression, filter: SearchFilter, limit: Int) -> [AVerse]? {
        let sql = expression.toSQL()
        return searchWithExpressionComponentsUnlocked(
            baseWhereClause: sql.whereClause,
            searchTerms: sql.terms,
            bookNumbers: filter.bookNumbers(),
            limit: limit
        )
    }

    private func searchWithExpressionComponentsUnlocked(
        baseWhereClause: String,
        searchTerms: [String],
        bookNumbers: [Int]?,
        limit: Int
    ) -> [AVerse]? {
        var whereClause = baseWhereClause

        if let numbers = bookNumbers {
            let placeholders = numbers.map { _ in "?" }.joined(separator: ",")
            whereClause = "(\(whereClause)) AND bnumber IN (\(placeholders))"
        }

        let queryStatementString = """
            SELECT * FROM bible
                WHERE \(whereClause)
                ORDER BY bnumber, cnumber, vnumber
                LIMIT ?;
        """

        return runSearchQueryWithExpressionAndFilter(
            queryStatementString: queryStatementString,
            searchTerms: searchTerms,
            bookNumbers: bookNumbers,
            limit: limit
        )
    }

    private func cachedStatement(
        statement: inout OpaquePointer?,
        query: String,
        context: String
    ) -> OpaquePointer? {
        guard let db else {
            return nil
        }

        if let statement {
            return statement
        }

        var newStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &newStatement, nil) == SQLITE_OK else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare \(context): \(errmsg)")
            return nil
        }

        statement = newStatement
        return newStatement
    }

    private func finalizeStatement(_ statement: inout OpaquePointer?) {
        guard let currentStatement = statement else {
            return
        }

        sqlite3_finalize(currentStatement)
        statement = nil
    }

    private func makeVerse(from statement: OpaquePointer?, fallbackBookName: String?) -> AVerse? {
        guard let statement else {
            return nil
        }

        guard let verseText = sqlite3_column_text(statement, 4) else {
            return nil
        }

        let bookNumber = Int(sqlite3_column_int(statement, 1))
        let bookName = fallbackBookName ?? Bible.bookNumberToName[bookNumber] ?? "Unknown"

        return AVerse(
            verseId: Int(sqlite3_column_int(statement, 0)),
            bookNumber: bookNumber,
            bookName: bookName,
            chapterNumber: Int(sqlite3_column_int(statement, 2)),
            verseNumber: Int(sqlite3_column_int(statement, 3)),
            verse: String(cString: verseText)
        )
    }

    private func runChapterCountQuery(queryStatementString: String, bookNumber: Int) -> Int32? {
        guard db != nil else {
            return nil
        }
        var count: Int32?
        var queryStatement: OpaquePointer?

        guard sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare chapter count query: \(errmsg)")
            return nil
        }

        // Bind the book number parameter
        sqlite3_bind_int(queryStatement, 1, Int32(bookNumber))

        if sqlite3_step(queryStatement) == SQLITE_ROW {
            count = sqlite3_column_int(queryStatement, 0)
        }

        sqlite3_finalize(queryStatement)
        return count
    }

    private func runSearchQuery(queryStatementString: String, searchPattern: String, limit: Int) -> [AVerse]? {
        guard db != nil else {
            return nil
        }
        var verses: [AVerse] = []
        var queryStatement: OpaquePointer?

        guard sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare search query: \(errmsg)")
            return nil
        }

        // Bind parameters: search pattern and limit
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(queryStatement, 1, (searchPattern as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(queryStatement, 2, Int32(limit))

        while sqlite3_step(queryStatement) == SQLITE_ROW {
            let verseId = sqlite3_column_int(queryStatement, 0)
            let bookNumber = sqlite3_column_int(queryStatement, 1)
            let chapterNumber = sqlite3_column_int(queryStatement, 2)
            let verseNumber = sqlite3_column_int(queryStatement, 3)

            guard let verseText = sqlite3_column_text(queryStatement, 4) else {
                continue
            }
            let verse = String(cString: verseText)

            // Look up book name from number using cached mapping
            let bookName = Bible.bookNumberToName[Int(bookNumber)] ?? "Unknown"

            verses.append(AVerse(
                verseId: Int(verseId),
                bookNumber: Int(bookNumber),
                bookName: bookName,
                chapterNumber: Int(chapterNumber),
                verseNumber: Int(verseNumber),
                verse: verse
            ))
        }

        sqlite3_finalize(queryStatement)
        return verses.isEmpty ? nil : verses
    }

    private func runSearchQueryWithFilter(
        queryStatementString: String,
        searchPattern: String,
        bookNumbers: [Int]?,
        limit: Int
    ) -> [AVerse]? {
        guard db != nil else {
            return nil
        }
        var verses: [AVerse] = []
        var queryStatement: OpaquePointer?

        guard sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare search query: \(errmsg)")
            return nil
        }

        // Bind parameters: search pattern, book numbers (if any), and limit
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var paramIndex: Int32 = 1

        // Bind search pattern
        sqlite3_bind_text(queryStatement, paramIndex, (searchPattern as NSString).utf8String, -1, SQLITE_TRANSIENT)
        paramIndex += 1

        // Bind book numbers if present
        if let bookNumbers = bookNumbers {
            for bookNum in bookNumbers {
                sqlite3_bind_int(queryStatement, paramIndex, Int32(bookNum))
                paramIndex += 1
            }
        }

        // Bind limit
        sqlite3_bind_int(queryStatement, paramIndex, Int32(limit))

        while sqlite3_step(queryStatement) == SQLITE_ROW {
            let verseId = sqlite3_column_int(queryStatement, 0)
            let bookNumber = sqlite3_column_int(queryStatement, 1)
            let chapterNumber = sqlite3_column_int(queryStatement, 2)
            let verseNumber = sqlite3_column_int(queryStatement, 3)

            guard let verseText = sqlite3_column_text(queryStatement, 4) else {
                continue
            }
            let verse = String(cString: verseText)

            // Look up book name from number using cached mapping
            let bookName = Bible.bookNumberToName[Int(bookNumber)] ?? "Unknown"

            verses.append(AVerse(
                verseId: Int(verseId),
                bookNumber: Int(bookNumber),
                bookName: bookName,
                chapterNumber: Int(chapterNumber),
                verseNumber: Int(verseNumber),
                verse: verse
            ))
        }

        sqlite3_finalize(queryStatement)
        return verses.isEmpty ? nil : verses
    }

    private func runSearchQueryWithExpressionAndFilter(
        queryStatementString: String,
        searchTerms: [String],
        bookNumbers: [Int]?,
        limit: Int
    ) -> [AVerse]? {
        guard db != nil else {
            return nil
        }
        var verses: [AVerse] = []
        var queryStatement: OpaquePointer?

        guard sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare search query: \(errmsg)")
            return nil
        }

        // Bind search terms
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var paramIndex: Int32 = 1

        for term in searchTerms {
            sqlite3_bind_text(queryStatement, paramIndex, (term as NSString).utf8String, -1, SQLITE_TRANSIENT)
            paramIndex += 1
        }

        // Bind book numbers if present
        if let bookNumbers = bookNumbers {
            for bookNum in bookNumbers {
                sqlite3_bind_int(queryStatement, paramIndex, Int32(bookNum))
                paramIndex += 1
            }
        }

        // Bind limit
        sqlite3_bind_int(queryStatement, paramIndex, Int32(limit))

        while sqlite3_step(queryStatement) == SQLITE_ROW {
            let verseId = sqlite3_column_int(queryStatement, 0)
            let bookNumber = sqlite3_column_int(queryStatement, 1)
            let chapterNumber = sqlite3_column_int(queryStatement, 2)
            let verseNumber = sqlite3_column_int(queryStatement, 3)

            guard let verseText = sqlite3_column_text(queryStatement, 4) else {
                continue
            }
            let verse = String(cString: verseText)

            // Look up book name from number using cached mapping
            let bookName = Bible.bookNumberToName[Int(bookNumber)] ?? "Unknown"

            verses.append(AVerse(
                verseId: Int(verseId),
                bookNumber: Int(bookNumber),
                bookName: bookName,
                chapterNumber: Int(chapterNumber),
                verseNumber: Int(verseNumber),
                verse: verse
            ))
        }

        sqlite3_finalize(queryStatement)
        return verses.isEmpty ? nil : verses
    }

    private func getVersesUnlocked(for coordinates: [(bookNumber: Int, chapterNumber: Int, verseNumber: Int)]) -> [AVerse] {
        guard let db = db, !coordinates.isEmpty else { return [] }

        let query = """
            SELECT id, bnumber, cnumber, vnumber, verse
            FROM bible
            WHERE bnumber = ? AND cnumber = ? AND vnumber = ?
            LIMIT 1;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var verses: [AVerse] = []
        verses.reserveCapacity(coordinates.count)

        for coordinate in coordinates {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int(statement, 1, Int32(coordinate.bookNumber))
            sqlite3_bind_int(statement, 2, Int32(coordinate.chapterNumber))
            sqlite3_bind_int(statement, 3, Int32(coordinate.verseNumber))

            guard sqlite3_step(statement) == SQLITE_ROW else { continue }
            guard let verseText = sqlite3_column_text(statement, 4) else { continue }

            let bnumber = Int(sqlite3_column_int(statement, 1))
            verses.append(AVerse(
                verseId: Int(sqlite3_column_int(statement, 0)),
                bookNumber: bnumber,
                bookName: Bible.bookNumberToName[bnumber] ?? "Unknown",
                chapterNumber: Int(sqlite3_column_int(statement, 2)),
                verseNumber: Int(sqlite3_column_int(statement, 3)),
                verse: String(cString: verseText)
            ))
        }

        return verses
    }
}
