import Foundation
import SQLite3
import Darwin

enum BibleImportError: LocalizedError {
    case invalidFileName
    case invalidSQLiteDatabase(String)
    case invalidBibleSchema(String)
    case incompatibleBible(String)
    case bundledBibleImportBlocked(String)
    case bibleAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidFileName:
            return "Invalid filename. Expected format: <LANG>_<NAME>.bible (example: ENG_UKJV.bible)."
        case .invalidSQLiteDatabase(let fileName):
            return "\(fileName) is not a valid SQLite database."
        case .invalidBibleSchema(let fileName):
            return "\(fileName) does not contain the required Bible schema."
        case .incompatibleBible(let message):
            return message
        case .bundledBibleImportBlocked(let fileName):
            return "Cannot import bundled Bible: \(fileName)."
        case .bibleAlreadyExists(let fileName):
            return "Bible file already exists: \(fileName)."
        }
    }
}

actor BibleImportService {
    func importBible(selectedFile: URL, bundledBibleNames: Set<String>, destinationDirectory: URL? = nil, replaceExisting: Bool = false) throws -> URL {
        let fileName = selectedFile.lastPathComponent
        guard BibleFileRule.isValidFileName(fileName) else { throw BibleImportError.invalidFileName }
        guard !bundledBibleNames.contains(fileName) else { throw BibleImportError.bundledBibleImportBlocked(fileName) }
        guard isSQLiteDatabase(url: selectedFile) else { throw BibleImportError.invalidSQLiteDatabase(fileName) }
        let destination = try destinationDirectory?.appendingPathComponent(fileName) ?? destinationURL(for: fileName)
        if !replaceExisting && FileManager.default.fileExists(atPath: destination.path) {
            throw BibleImportError.bibleAlreadyExists(fileName)
        }
        return try copyBibleFileAtomically(from: selectedFile, to: destination, replaceExisting: replaceExisting)
    }

    private func destinationURL(for fileName: String) throws -> URL {
        let documentsDirectory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documentsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func copyBibleFileAtomically(from sourceURL: URL, to destinationURL: URL, replaceExisting: Bool) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = destinationURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).import")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        // SQLite backup captures a consistent snapshot, including committed WAL content.
        try snapshot(from: sourceURL, to: temporaryURL)
        guard hasBibleSchema(url: temporaryURL) else { throw BibleImportError.invalidBibleSchema(sourceURL.lastPathComponent) }
        if let error = canonicalCompatibilityError(url: temporaryURL, fileName: sourceURL.lastPathComponent) { throw error }
        try indexCoordinates(at: temporaryURL)
        setReadOnlyPermissionsIfPossible(for: temporaryURL)
        if replaceExisting {
            guard rename(temporaryURL.path, destinationURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else { try fileManager.moveItem(at: temporaryURL, to: destinationURL) }
        return destinationURL
    }

    private func snapshot(from source: URL, to destination: URL) throws {
        var input: OpaquePointer?, output: OpaquePointer?
        defer { sqlite3_close(input); sqlite3_close(output) }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw BibleImportError.invalidSQLiteDatabase(source.lastPathComponent)
        }
        sqlite3_busy_timeout(input, 3_000)
        let status = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE && finish == SQLITE_OK else {
            throw BibleImportError.incompatibleBible("Could not copy a consistent database snapshot. Close the program editing this file and try again.")
        }
        // Imported files are standalone and read-only. Do not carry WAL mode or
        // a dependency on sidecar files into the normalized copy.
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE;", nil, nil, nil) == SQLITE_OK else {
            throw BibleImportError.incompatibleBible("Could not finalize the imported database snapshot.")
        }
    }

    private func indexCoordinates(at url: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              sqlite3_exec(db, "DROP INDEX IF EXISTS vtw_verse_coordinates; CREATE UNIQUE INDEX vtw_verse_coordinates ON bible(bnumber, cnumber, vnumber);", nil, nil, nil) == SQLITE_OK else {
            throw BibleImportError.incompatibleBible("Could not index the imported translation.")
        }
    }

    private func setReadOnlyPermissionsIfPossible(for url: URL) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        } catch {
            logger.warning("Failed to set read-only permissions for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func isSQLiteDatabase(url: URL) -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fileHandle.close() }

        guard let header = try? fileHandle.read(upToCount: 16), header.count == 16 else { return false }
        let sqliteHeader = "SQLite format 3\0".data(using: .utf8)
        return header == sqliteHeader
    }

    private func hasBibleSchema(url: URL) -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, "PRAGMA table_info(bible);", -1, &statement, nil) == SQLITE_OK else {
            return false
        }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let columnNameCStr = sqlite3_column_text(statement, 1) else { continue }
            let columnName = String(cString: columnNameCStr).lowercased()
            columns.insert(columnName)
        }

        return BibleFileRule.requiredBibleColumns.isSubset(of: columns)
    }

    private func canonicalCompatibilityError(url: URL, fileName: String) -> BibleImportError? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return .incompatibleBible("\(fileName) cannot be validated for canonical book compatibility.")
        }

        guard querySingleInt(db: db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('bible', 'bnames')") == 2 else {
            return .invalidBibleSchema(fileName)
        }
        guard querySingleInt(db: db, sql: "SELECT COUNT(*) FROM bible WHERE typeof(bnumber) != 'integer' OR typeof(cnumber) != 'integer' OR typeof(vnumber) != 'integer' OR typeof(verse) != 'text' OR bnumber < 1 OR bnumber > 66 OR cnumber < 1 OR cnumber > 150 OR vnumber < 1 OR vnumber > 2147483647") == 0 else {
            return .incompatibleBible("Verse coordinates must be positive integers in range, and verses must contain text.")
        }
        guard querySingleInt(db: db, sql: "SELECT COUNT(*) FROM (SELECT 1 FROM bible GROUP BY bnumber, cnumber, vnumber HAVING COUNT(*) > 1)") == 0 else {
            return .incompatibleBible("The translation contains duplicate verse coordinates.")
        }
        guard querySingleInt(db: db, sql: "SELECT COUNT(*) FROM pragma_integrity_check WHERE integrity_check != 'ok'") == 0 else {
            return .invalidSQLiteDatabase(fileName)
        }

        let expectedByBookNumber = Dictionary(
            uniqueKeysWithValues: bibleBooks.values.compactMap { value -> (Int, Int)? in
                guard value.count >= 2 else { return nil }
                return (value[0], value[1])
            }
        )
        let expectedBookCount = expectedByBookNumber.count
        let expectedBookNumbers = Set(expectedByBookNumber.keys)

        guard let bnamesCount = querySingleInt(db: db, sql: "SELECT COUNT(*) FROM bnames;") else {
            return .incompatibleBible("\(fileName) must include table `bnames` with \(expectedBookCount) entries.")
        }
        guard bnamesCount == expectedBookCount else {
            return .incompatibleBible("\(fileName) has \(bnamesCount) `bnames` entries; expected \(expectedBookCount).")
        }

        guard let chapterStats = loadChapterStatsByBook(db: db) else {
            return .incompatibleBible("\(fileName) cannot be validated for canonical chapter coverage.")
        }
        let actualBookNumbers = Set(chapterStats.keys)
        guard actualBookNumbers == expectedBookNumbers else {
            return .incompatibleBible("\(fileName) must have canonical book numbers 1...\(expectedBookCount) in table `bible`.")
        }

        for (bookNumber, expectedChapters) in expectedByBookNumber.sorted(by: { $0.key < $1.key }) {
            guard let stats = chapterStats[bookNumber] else {
                return .incompatibleBible("\(fileName) is missing verses for book number \(bookNumber).")
            }
            if stats.minChapter != 1 || stats.maxChapter != expectedChapters || stats.distinctChapterCount != expectedChapters {
                return .incompatibleBible(
                    "\(fileName) chapter coverage mismatch for book \(bookNumber): expected 1...\(expectedChapters)."
                )
            }
        }

        return nil
    }

    private func querySingleInt(db: OpaquePointer?, sql: String) -> Int? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func loadChapterStatsByBook(db: OpaquePointer?) -> [Int: (minChapter: Int, maxChapter: Int, distinctChapterCount: Int)]? {
        let sql = """
            SELECT bnumber, MIN(cnumber), MAX(cnumber), COUNT(DISTINCT cnumber)
            FROM bible
            GROUP BY bnumber
            ORDER BY bnumber;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        var result: [Int: (minChapter: Int, maxChapter: Int, distinctChapterCount: Int)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let bookNumber = Int(sqlite3_column_int(statement, 0))
            let minChapter = Int(sqlite3_column_int(statement, 1))
            let maxChapter = Int(sqlite3_column_int(statement, 2))
            let distinctChapterCount = Int(sqlite3_column_int(statement, 3))
            result[bookNumber] = (minChapter: minChapter, maxChapter: maxChapter, distinctChapterCount: distinctChapterCount)
        }

        return result
    }
}
