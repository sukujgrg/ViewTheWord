import Foundation
import SQLite3

enum BibleError: LocalizedError, Equatable {
    case database(String), invalidData(String)
    var errorDescription: String? {
        switch self {
        case .database(let detail): return "Could not read the Bible database: \(detail)"
        case .invalidData(let detail): return "The Bible database is invalid: \(detail)"
        }
    }
}

protocol BibleReading: Sendable {
    func chapter(_ reference: VerseReference) async throws -> [AVerse]
    func verses(_ references: [VerseReference]) async throws -> [AVerse]
    func search(_ request: TextSearchRequest, after: VerseCoordinate?, limit: Int) async throws -> [AVerse]
}

/// Every SQLite pointer and statement is confined to dbQueue, including open and close.
final class Bible: BibleReading, @unchecked Sendable {
    let dbUrl: URL
    private let dbQueue = DispatchQueue(label: "com.viewtheword.database", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var db: OpaquePointer?
    private var chapterStatement: OpaquePointer?
    private static let columns = "bnumber, cnumber, vnumber, verse"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(dbUrl: URL) {
        self.dbUrl = dbUrl
        dbQueue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        let close = {
            sqlite3_finalize(self.chapterStatement)
            if let db = self.db { sqlite3_close_v2(db) }
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { close() }
        else { dbQueue.sync(execute: close) }
    }

    private func connection() throws -> OpaquePointer {
        if let db { return db }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbUrl.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let opened = handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "File cannot be opened."
            if let handle { sqlite3_close_v2(handle) }
            throw BibleError.database(detail)
        }
        sqlite3_busy_timeout(opened, 3_000)
        let status = sqlite3_create_function_v2(opened, "word_matches", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { context, count, values in
            guard let context, count == 2, let values,
                  let rawText = sqlite3_value_text(values[0]), let rawTerm = sqlite3_value_text(values[1]) else {
                sqlite3_result_int(context, 0)
                return
            }
            let matcher: WordMatcher
            if let cached = sqlite3_get_auxdata(context, 1) {
                matcher = Unmanaged<WordMatcher>.fromOpaque(cached).takeUnretainedValue()
            } else {
                do { matcher = try WordMatcher(term: String(cString: rawTerm)) }
                catch { sqlite3_result_error(context, "Invalid word matcher", -1); return }
                sqlite3_set_auxdata(context, 1, Unmanaged.passRetained(matcher).toOpaque(), { pointer in
                    if let pointer { Unmanaged<WordMatcher>.fromOpaque(pointer).release() }
                })
            }
            sqlite3_result_int(context, matcher.matches(String(cString: rawText)) ? 1 : 0)
        }, nil, nil, nil)
        guard status == SQLITE_OK else {
            sqlite3_close_v2(opened)
            throw BibleError.database("Could not initialize word search.")
        }
        db = opened
        return opened
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable (Bible) throws -> T) async throws -> T {
        try Task.checkCancellation()
        let result: T = try await withCheckedThrowingContinuation { continuation in
            dbQueue.async { [self] in continuation.resume(with: Result { try work(self) }) }
        }
        try Task.checkCancellation()
        return result
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let db = try connection()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw BibleError.database(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func bind(_ number: Int, at index: Int32, to statement: OpaquePointer) throws {
        guard let checked = Int32(exactly: number), sqlite3_bind_int(statement, index, checked) == SQLITE_OK else {
            throw BibleError.invalidData("Coordinate or result limit is out of range.")
        }
    }
    private func bind(_ text: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, text, -1, Self.transient) == SQLITE_OK else {
            throw BibleError.database("Could not bind search text.")
        }
    }

    private func read(_ statement: OpaquePointer) throws -> [AVerse] {
        var result: [AVerse] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard (0...2).allSatisfy({ sqlite3_column_type(statement, Int32($0)) == SQLITE_INTEGER }),
                  sqlite3_column_type(statement, 3) == SQLITE_TEXT else {
                throw BibleError.invalidData("Verse coordinates must be integers and verse text must be text.")
            }
            let book = sqlite3_column_int64(statement, 0)
            let chapter = sqlite3_column_int64(statement, 1)
            let verse = sqlite3_column_int64(statement, 2)
            guard let metadata = bibleBookMetadata.first(where: { $0.number == book }),
                  let chapterNumber = Int(exactly: chapter), let verseNumber = Int(exactly: verse),
                  let reference = VerseReference(book: metadata.name, chapter: chapterNumber, verse: verseNumber),
                  let raw = sqlite3_column_text(statement, 3) else {
                throw BibleError.invalidData("A verse has invalid coordinates or missing text.")
            }
            result.append(AVerse(reference: reference, verse: String(cString: raw)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw BibleError.database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "Query failed.")
        }
        return result
    }

    func chapter(_ reference: VerseReference) async throws -> [AVerse] {
        try await perform { reader in
            if reader.chapterStatement == nil {
                reader.chapterStatement = try reader.prepare("SELECT \(Self.columns) FROM bible WHERE bnumber = ? AND cnumber = ? ORDER BY vnumber")
            }
            let statement = reader.chapterStatement!
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try reader.bind(reference.coordinate.book, at: 1, to: statement)
            try reader.bind(reference.chapter, at: 2, to: statement)
            return try reader.read(statement)
        }
    }

    func verses(_ references: [VerseReference]) async throws -> [AVerse] {
        guard !references.isEmpty else { return [] }
        return try await perform { reader in
            var results: [AVerse] = []
            for start in stride(from: 0, to: references.count, by: 100) {
                let batch = Array(references[start..<min(start + 100, references.count)])
                let conditions = Array(repeating: "(bnumber = ? AND cnumber = ? AND vnumber = ?)", count: batch.count).joined(separator: " OR ")
                let statement = try reader.prepare("SELECT \(Self.columns) FROM bible WHERE \(conditions) ORDER BY bnumber, cnumber, vnumber")
                defer { sqlite3_finalize(statement) }
                for (index, reference) in batch.enumerated() {
                    try reader.bind(reference.coordinate.book, at: Int32(index * 3 + 1), to: statement)
                    try reader.bind(reference.chapter, at: Int32(index * 3 + 2), to: statement)
                    try reader.bind(reference.verse, at: Int32(index * 3 + 3), to: statement)
                }
                results += try reader.read(statement)
            }
            return results
        }
    }

    func search(_ request: TextSearchRequest, after: VerseCoordinate? = nil, limit: Int = 101) async throws -> [AVerse] {
        guard (1...10_000).contains(limit) else { throw BibleError.invalidData("Result limit is out of range.") }
        return try await perform { reader in
            var condition: String
            var terms: [String]
            switch request.kind {
            case .phrase(let text):
                condition = "verse LIKE ? ESCAPE '\\'"
                terms = ["%" + Self.escapeLike(text) + "%"]
            case .words(let expression): (condition, terms) = expression.toSQL()
            }
            var numbers: [Int] = []
            if let books = request.filter.bookNumbers() {
                condition = "(\(condition)) AND bnumber IN (\(Array(repeating: "?", count: books.count).joined(separator: ",")))"
                numbers += books
            }
            if let after {
                condition = "(\(condition)) AND (bnumber, cnumber, vnumber) > (?, ?, ?)"
                numbers += [after.book, after.chapter, after.verse]
            }
            let statement = try reader.prepare("SELECT \(Self.columns) FROM bible WHERE \(condition) ORDER BY bnumber, cnumber, vnumber LIMIT ?")
            defer { sqlite3_finalize(statement) }
            for (index, term) in terms.enumerated() { try reader.bind(term, at: Int32(index + 1), to: statement) }
            numbers.append(limit)
            for (index, number) in numbers.enumerated() { try reader.bind(number, at: Int32(terms.count + index + 1), to: statement) }
            return try reader.read(statement)
        }
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

/// Combining marks and joiners are part of a word, including Malayalam conjuncts.
final class WordMatcher {
    private let expression: NSRegularExpression
    init(term: String) throws {
        let literal = NSRegularExpression.escapedPattern(for: term.precomposedStringWithCanonicalMapping)
        let word = #"[\p{L}\p{M}\p{N}_\x{200C}\x{200D}]"#
        expression = try NSRegularExpression(pattern: "(?<!\(word))\(literal)(?!\(word))", options: .caseInsensitive)
    }
    func matches(_ text: String) -> Bool {
        let normalized = text.precomposedStringWithCanonicalMapping
        return expression.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil
    }
}
