import Foundation
import OrderedCollections
import SQLite3

struct AVerse {
    let verseId: Int
    let bookNumber: Int
    let bookName: String
    let chapterNumber: Int
    let verseNumber: Int
    let verse: String
}

class BibleUrl {
    var primaryBibleUrl: URL
    var secondaryBibleUrl: URL

    init() {
        // Initialize with default values first
        primaryBibleUrl = bundledPrimaryBibleUrl ?? URL(fileURLWithPath: "/")
        secondaryBibleUrl = bundledSecondaryBibleUrl ?? URL(fileURLWithPath: "/")

        // Now we can safely call instance methods
        if let primary = self.getBibleUrl(defaultsKey: "PrimaryBibleName") {
            primaryBibleUrl = primary
        } else if let bundledPrimary = bundledPrimaryBibleUrl {
            primaryBibleUrl = bundledPrimary
        } else {
            fatalError("Primary Bible resource not found in bundle. Ensure MAL_BSI.bible exists.")
        }

        if let secondary = self.getBibleUrl(defaultsKey: "SecondaryBibleName") {
            secondaryBibleUrl = secondary
        } else if let bundledSecondary = bundledSecondaryBibleUrl {
            secondaryBibleUrl = bundledSecondary
        } else {
            fatalError("Secondary Bible resource not found in bundle. Ensure ENG_UKJV.bible exists.")
        }
    }

    func getBibleUrl(defaultsKey: String) -> URL? {
        let availableBibleUrls = getAvailableBibleUrls()

        let defaults = UserDefaults.standard

        if let bibleName = defaults.string(forKey: defaultsKey) {
            for url in availableBibleUrls {
                let bibleNameUrl = URL(string: bibleName)
                if url.lastPathComponent == bibleNameUrl?.lastPathComponent {
                    return url
                }
            }
        }
        return nil
    }

    func getAvailableBibleUrls() -> [URL] {
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
                $0.pathExtension == "bible" && isValidBibleFileName(selectedFileName: $0.lastPathComponent)
            }
            availableBibleUrls += bibleDbUrls
        } catch {
            logger.error("\(documentsURL.path): \(error.localizedDescription)")
        }
        return availableBibleUrls
    }

    private func isValidBibleFileName(selectedFileName: String) -> Bool {
        return selectedFileName.range(of: #"\b[A-Z]{3}_[A-Z]{3,6}\.bible\b"#, options: .regularExpression) != nil
    }
}

class Bible {
    let dbUrl: URL
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.viewtheword.database", qos: .userInitiated)

    init(dbUrl: URL) {
        self.dbUrl = dbUrl
        db = openDb()
    }

    deinit {
        self.closeDb()
    }

    func closeDb() {
        dbQueue.sync {
            if let db = db, sqlite3_close_v2(db) != SQLITE_OK {
                logger.error("Error closing \(self.dbUrl.absoluteString).")
            }
            db = nil
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
        return dbQueue.sync {
            guard let bookNumber = bookNumber(bookName: bookName) else {
                return nil
            }
            let q = "SELECT COUNT(DISTINCT cnumber) FROM bible WHERE bnumber = ?;"
            return runChapterCountQuery(queryStatementString: q, bookNumber: bookNumber)
        }
    }

    func pickAVerse(verseQuery: VerseQuery) -> AVerse? {
        return dbQueue.sync {
            guard let bookNumber = bookNumber(bookName: verseQuery.bookName) else {
                return nil
            }
            let queryStatementString = """
                SELECT * FROM bible
                    WHERE
                        bnumber = ? AND
                        cnumber = ? AND
                        vnumber = ?;
            """
            if let result = runVerseQuery(
                queryStatementString: queryStatementString,
                verseQuery: verseQuery,
                parameters: [bookNumber, verseQuery.chapterNumber, verseQuery.verseNumber]
            ) {
                return result.first
            } else {
                return nil
            }
        }
    }

    func pickAChapter(verseQuery: VerseQuery) -> [AVerse]? {
        return dbQueue.sync {
            guard let bookNumber = bookNumber(bookName: verseQuery.bookName) else {
                return nil
            }
            let queryStatementString = """
                SELECT * FROM bible
                    WHERE
                        bnumber = ? AND
                        cnumber = ?;
            """
            return runVerseQuery(
                queryStatementString: queryStatementString,
                verseQuery: verseQuery,
                parameters: [bookNumber, verseQuery.chapterNumber]
            )
        }
    }

    func searchText(searchQuery: String, limit: Int = 100) -> [AVerse]? {
        return dbQueue.sync {
            // Use LIKE for case-insensitive search
            let queryStatementString = """
                SELECT * FROM bible
                    WHERE verse LIKE ?
                    ORDER BY bnumber, cnumber, vnumber
                    LIMIT ?;
            """
            return runSearchQuery(queryStatementString: queryStatementString, searchPattern: "%\(searchQuery)%", limit: limit)
        }
    }

    func searchTextWithFilter(searchQuery: String, filter: SearchFilter, limit: Int = 100) -> [AVerse]? {
        return dbQueue.sync {
            var whereClause = "verse LIKE ?"

            // Add book filter if specified
            if let bookNumbers = filter.bookNumbers() {
                let bookNumbersStr = bookNumbers.map { String($0) }.joined(separator: ",")
                whereClause = "(\(whereClause)) AND bnumber IN (\(bookNumbersStr))"
            }

            let queryStatementString = """
                SELECT * FROM bible
                    WHERE \(whereClause)
                    ORDER BY bnumber, cnumber, vnumber
                    LIMIT ?;
            """
            return runSearchQuery(queryStatementString: queryStatementString, searchPattern: "%\(searchQuery)%", limit: limit)
        }
    }

    func searchWithExpression(expression: SearchExpression, filter: SearchFilter, limit: Int = 100) -> [AVerse]? {
        return dbQueue.sync {
            let sql = expression.toSQL()
            var whereClause = sql.whereClause

            // Add book filter if specified
            if let bookNumbers = filter.bookNumbers() {
                let bookNumbersStr = bookNumbers.map { String($0) }.joined(separator: ",")
                whereClause = "(\(whereClause)) AND bnumber IN (\(bookNumbersStr))"
            }

            let queryStatementString = """
                SELECT * FROM bible
                    WHERE \(whereClause)
                    ORDER BY bnumber, cnumber, vnumber
                    LIMIT ?;
            """

            return runSearchQueryWithExpression(
                queryStatementString: queryStatementString,
                searchTerms: sql.terms,
                limit: limit
            )
        }
    }

    private func runSearchQueryWithExpression(queryStatementString: String, searchTerms: [String], limit: Int) -> [AVerse]? {
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
        for (index, term) in searchTerms.enumerated() {
            sqlite3_bind_text(queryStatement, Int32(index + 1), (term as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }

        // Bind limit
        sqlite3_bind_int(queryStatement, Int32(searchTerms.count + 1), Int32(limit))

        while sqlite3_step(queryStatement) == SQLITE_ROW {
            let verseId = sqlite3_column_int(queryStatement, 0)
            let bookNumber = sqlite3_column_int(queryStatement, 1)
            let chapterNumber = sqlite3_column_int(queryStatement, 2)
            let verseNumber = sqlite3_column_int(queryStatement, 3)

            guard let verseText = sqlite3_column_text(queryStatement, 4) else {
                continue
            }
            let verse = String(cString: verseText)

            // Look up book name from number
            let bookName = bibleBooks.first { $0.value[0] == Int(bookNumber) }?.key ?? "Unknown"

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

    private func runVerseQuery(
        queryStatementString: String,
        verseQuery: VerseQuery,
        parameters: [Int] = []
    ) -> [AVerse]? {
        guard db != nil else {
            return nil
        }
        var verses: [AVerse] = []

        var queryStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to prepare query: \(errmsg)")
            return nil
        }

        // Bind parameters
        for (index, parameter) in parameters.enumerated() {
            sqlite3_bind_int(queryStatement, Int32(index + 1), Int32(parameter))
        }

        while sqlite3_step(queryStatement) == SQLITE_ROW {
            let verseId = sqlite3_column_int(queryStatement, 0)
            let bookNumber = sqlite3_column_int(queryStatement, 1)
            let chapterNumber = sqlite3_column_int(queryStatement, 2)
            let verseNumber = sqlite3_column_int(queryStatement, 3)

            guard let verseText = sqlite3_column_text(queryStatement, 4) else {
                continue
            }
            let verse = String(cString: verseText)

            verses.append(AVerse(
                verseId: Int(verseId),
                bookNumber: Int(bookNumber),
                bookName: verseQuery.bookName,
                chapterNumber: Int(chapterNumber),
                verseNumber: Int(verseNumber),
                verse: verse
            ))
        }

        sqlite3_finalize(queryStatement)

        return verses.isEmpty ? nil : verses
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

            // Look up book name from number
            let bookName = bibleBooks.first { $0.value[0] == Int(bookNumber) }?.key ?? "Unknown"

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
}
