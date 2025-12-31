import Foundation
import OSLog
import SQLite3

/// Manages a standalone embeddings database that works with any Bible translation
class EmbeddingsDb {
    private let dbUrl: URL
    private var db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.viewtheword.embeddings.dbQueue")

    init(dbUrl: URL) {
        self.dbUrl = dbUrl
        self.db = openDb()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    /// Open the embeddings database
    private func openDb() -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(self.dbUrl.path, &db, SQLite3.SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            logger.error("Failed to open embeddings database at: \(self.dbUrl.path)")
            return nil
        }
        return db
    }

    /// Check if embeddings table exists
    func hasEmbeddingsTable() -> Bool {
        return dbQueue.sync {
            guard let db = db else { return false }

            let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='embeddings';"
            var statement: OpaquePointer?

            defer { sqlite3_finalize(statement) }

            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                return false
            }

            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    /// Get the count of embeddings
    func getEmbeddingCount() -> Int {
        return dbQueue.sync {
            guard let db = db else { return 0 }

            let query = "SELECT COUNT(*) FROM embeddings;"
            var statement: OpaquePointer?

            defer { sqlite3_finalize(statement) }

            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                if sqlite3_step(statement) == SQLITE_ROW {
                    return Int(sqlite3_column_int(statement, 0))
                }
            }

            return 0
        }
    }

    /// Search embeddings by semantic similarity and return verse coordinates
    /// Returns array of (book_number, chapter_number, verse_number, similarity)
    nonisolated func searchBySemantic(queryEmbedding: [Float], filter: SearchFilter, limit: Int = 15, minSimilarity: Float) -> [(bookNumber: Int, chapterNumber: Int, verseNumber: Int, similarity: Float)]? {
        return dbQueue.sync {
            guard let db = db else { return [] }

            // Build WHERE clause for filter
            var whereClause = "1=1"
            var bookNumbers: [Int]? = nil

            if let numbers = filter.bookNumbers() {
                bookNumbers = numbers
                let placeholders = numbers.map { _ in "?" }.joined(separator: ",")
                whereClause = "\(whereClause) AND book_number IN (\(placeholders))"
            }

            let query = """
                SELECT book_number, chapter_number, verse_number, embedding
                FROM embeddings
                WHERE \(whereClause);
            """

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                let errmsg = String(cString: sqlite3_errmsg(db))
                logger.error("Failed to prepare embeddings search: \(errmsg)")
                return nil
            }

            // Bind book number filters if present
            if let bookNumbers = bookNumbers {
                var paramIndex: Int32 = 1
                for bookNum in bookNumbers {
                    sqlite3_bind_int(statement, paramIndex, Int32(bookNum))
                    paramIndex += 1
                }
            }

            // Calculate similarities
            var results: [(bookNumber: Int, chapterNumber: Int, verseNumber: Int, similarity: Float)] = []

            while sqlite3_step(statement) == SQLITE_ROW {
                let bookNumber = Int(sqlite3_column_int(statement, 0))
                let chapterNumber = Int(sqlite3_column_int(statement, 1))
                let verseNumber = Int(sqlite3_column_int(statement, 2))

                // Extract embedding blob
                guard let embeddingBlob = sqlite3_column_blob(statement, 3) else { continue }
                let embeddingSize = sqlite3_column_bytes(statement, 3)
                let embeddingData = Data(bytes: embeddingBlob, count: Int(embeddingSize))

                // Convert blob back to [Float]
                let embeddingArray = embeddingData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> [Float] in
                    let floatPtr = ptr.bindMemory(to: Float.self)
                    return Array(floatPtr)
                }

                // Calculate similarity
                let similarity = OpenAIClient.cosineSimilarity(queryEmbedding, embeddingArray)

                results.append((bookNumber: bookNumber, chapterNumber: chapterNumber, verseNumber: verseNumber, similarity: similarity))
            }

            sqlite3_finalize(statement)

            // Sort by similarity (highest first), filter by minimum similarity, and take top N
            let sortedResults = results
                .sorted { $0.similarity > $1.similarity }
                .filter { $0.similarity >= minSimilarity }
                .prefix(limit)

            return Array(sortedResults)
        }
    }
}

/// Extension to create/update embeddings database (used by GenerateEmbeddings script)
extension EmbeddingsDb {
    /// Create embeddings table in a new database (for script usage)
    static func createEmbeddingsDatabase(at url: URL) -> Bool {
        var db: OpaquePointer?

        // Open with READWRITE and CREATE flags
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            logger.error("Failed to create embeddings database at: \(url.path)")
            return false
        }

        defer { sqlite3_close(db) }

        let createTable = """
            CREATE TABLE IF NOT EXISTS embeddings (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_number INTEGER NOT NULL,
                chapter_number INTEGER NOT NULL,
                verse_number INTEGER NOT NULL,
                embedding BLOB NOT NULL,
                model TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                UNIQUE(book_number, chapter_number, verse_number)
            );

            CREATE INDEX IF NOT EXISTS idx_book_chapter_verse
            ON embeddings(book_number, chapter_number, verse_number);
        """

        if sqlite3_exec(db, createTable, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            logger.error("Failed to create embeddings table: \(errmsg)")
            return false
        }

        return true
    }
}
