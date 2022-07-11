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
    var primaryBibleUrl: URL = bundledPrimaryBibleUrl
    var secondaryBibleUrl: URL = bundledSecondaryBibleUrl

    init() {
        if let primary = getBibleUrl(defaultsKey: "PrimaryBibleName") {
            primaryBibleUrl = primary
        } else {
            primaryBibleUrl = bundledPrimaryBibleUrl
        }
        if let secondary = getBibleUrl(defaultsKey: "SecondaryBibleName") {
            secondaryBibleUrl = secondary
        } else {
            secondaryBibleUrl = bundledSecondaryBibleUrl
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
        var availableBibleUrls: [URL] = [bundledPrimaryBibleUrl, bundledSecondaryBibleUrl]
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            let bibleDbUrls = fileURLs.filter { $0.pathExtension == "bible" }
            availableBibleUrls += bibleDbUrls
        } catch {
            logger.error("\(documentsURL.path): \(error.localizedDescription)")
        }
        return availableBibleUrls
    }
}

class Bible {
    let dbUrl: URL

    init(dbUrl: URL) {
        self.dbUrl = dbUrl
        db = openDb()
    }

    deinit {
        self.closeDb()
    }

    func closeDb() {
        if sqlite3_close_v2(db) != SQLITE_OK {
            logger.error("Error closing \(self.dbUrl.absoluteString).")
        }
    }

    var db: OpaquePointer?

    func openDb() -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(dbUrl.path, &db, SQLite3.SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            logger.error("\(errmsg)")
            return nil
        } else {
            return db
        }
    }

    func bookNumber(bookName: String) -> Int? {
        return bibleBooks[bookName]
    }

    func pickAVerse(verseQuery: VerseQuery) -> AVerse? {
        guard let bookNumber = bookNumber(bookName: verseQuery.bookName) else {
            return nil
        }
        let queryStatementString = "SELECT * FROM bible WHERE bnumber = \(bookNumber) AND cnumber LIKE '\(verseQuery.chapterNumber)' AND vnumber LIKE '\(verseQuery.verseNumber)';"
        if let result = runVerseQuery(queryStatementString: queryStatementString, verseQuery: verseQuery) {
            return result[0]
        } else {
            return nil
        }
    }

    func pickAChapter(verseQuery: VerseQuery) -> [AVerse]? {
        guard let bookNumber = bookNumber(bookName: verseQuery.bookName) else {
            return nil
        }
        let queryStatementString = "SELECT * FROM bible WHERE bnumber = '\(bookNumber)' and cnumber = \(verseQuery.chapterNumber);"
        return runVerseQuery(queryStatementString: queryStatementString, verseQuery: verseQuery)
    }

    private func runVerseQuery(queryStatementString: String, verseQuery: VerseQuery) -> [AVerse]? {
        guard let _ = db else {
            return nil
        }
        var verses: [AVerse] = []

        var queryStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, queryStatementString, -1, &queryStatement, nil) == SQLITE_OK {
            while sqlite3_step(queryStatement) == SQLITE_ROW {
                let verseId = sqlite3_column_int(queryStatement, 0)
                let bookNumber = sqlite3_column_int(queryStatement, 1)
                let chapterNumber = sqlite3_column_int(queryStatement, 2)
                let verseNumber = sqlite3_column_int(queryStatement, 3)
                let verse = String(describing: String(cString: sqlite3_column_text(queryStatement, 4)))
                verses.append(AVerse(
                    verseId: Int(verseId),
                    bookNumber: Int(bookNumber),
                    bookName: verseQuery.bookName,
                    chapterNumber: Int(chapterNumber),
                    verseNumber: Int(verseNumber),
                    verse: String(verse)
                ))
            }
        } else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            logger.error("\(errmsg)")
        }
        sqlite3_finalize(queryStatement)
        if verses.isEmpty {
            return nil
        }
        return verses
    }
}
