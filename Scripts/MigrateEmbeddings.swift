#!/usr/bin/swift
//
// MigrateEmbeddings.swift
// Migrate embeddings from old format (embedded in Bible file) to new standalone format
//
// Usage:
//   swift MigrateEmbeddings.swift SOURCE_BIBLE OUTPUT_EMBEDDINGS
//
// Example:
//   swift MigrateEmbeddings.swift ViewTheWord/ENG_UKJVS.bible ViewTheWord/embeddings.bible
//

import Foundation
import SQLite3

func printUsage() {
    print("""

    Usage:
      swift MigrateEmbeddings.swift SOURCE_BIBLE_FILE OUTPUT_EMBEDDINGS_FILE

    Arguments:
      SOURCE_BIBLE_FILE        Bible file containing embeddings table (e.g., ENG_UKJVS.bible)
      OUTPUT_EMBEDDINGS_FILE   Output path for standalone embeddings database

    Example:
      swift MigrateEmbeddings.swift ViewTheWord/ENG_UKJVS.bible ViewTheWord/embeddings.bible

    """)
}

func *(string: String, count: Int) -> String {
    return String(repeating: string, count: count)
}

func openSourceDatabase(path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
        print("❌ Failed to open source database at: \(path)")
        return nil
    }
    return db
}

func openDestinationDatabase(path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
        print("❌ Failed to create destination database at: \(path)")
        return nil
    }
    return db
}

func createEmbeddingsTable(db: OpaquePointer) -> Bool {
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
        print("❌ Failed to create embeddings table: \(errmsg)")
        return false
    }

    return true
}

func checkEmbeddingsTable(db: OpaquePointer) -> Bool {
    let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='embeddings';"
    var statement: OpaquePointer?

    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        return false
    }

    let hasTable = sqlite3_step(statement) == SQLITE_ROW
    sqlite3_finalize(statement)

    return hasTable
}

struct EmbeddingRecord {
    let bookNumber: Int
    let chapterNumber: Int
    let verseNumber: Int
    let embedding: Data
    let model: String
    let createdAt: Int64
}

func getAllEmbeddings(db: OpaquePointer) -> [EmbeddingRecord] {
    var embeddings: [EmbeddingRecord] = []

    // Join embeddings with bible table to get coordinates
    let query = """
        SELECT b.bnumber, b.cnumber, b.vnumber, e.embedding, e.model, e.created_at
        FROM embeddings e
        INNER JOIN bible b ON e.verse_id = b.id
        ORDER BY b.bnumber, b.cnumber, b.vnumber;
    """

    var statement: OpaquePointer?

    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        print("❌ Failed to prepare query to read embeddings")
        return []
    }

    while sqlite3_step(statement) == SQLITE_ROW {
        let bookNumber = Int(sqlite3_column_int(statement, 0))
        let chapterNumber = Int(sqlite3_column_int(statement, 1))
        let verseNumber = Int(sqlite3_column_int(statement, 2))

        guard let embeddingBlob = sqlite3_column_blob(statement, 3) else { continue }
        let embeddingSize = sqlite3_column_bytes(statement, 3)
        let embeddingData = Data(bytes: embeddingBlob, count: Int(embeddingSize))

        let model: String
        if let modelPtr = sqlite3_column_text(statement, 4) {
            model = String(cString: modelPtr)
        } else {
            model = "text-embedding-3-small"  // Default model
        }

        let createdAt = sqlite3_column_int64(statement, 5)

        embeddings.append(EmbeddingRecord(
            bookNumber: bookNumber,
            chapterNumber: chapterNumber,
            verseNumber: verseNumber,
            embedding: embeddingData,
            model: model,
            createdAt: createdAt
        ))
    }

    sqlite3_finalize(statement)
    return embeddings
}

func storeEmbedding(db: OpaquePointer, record: EmbeddingRecord) -> Bool {
    let query = """
        INSERT OR REPLACE INTO embeddings (book_number, chapter_number, verse_number, embedding, model, created_at)
        VALUES (?, ?, ?, ?, ?, ?);
    """

    var statement: OpaquePointer?

    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        return false
    }

    sqlite3_bind_int(statement, 1, Int32(record.bookNumber))
    sqlite3_bind_int(statement, 2, Int32(record.chapterNumber))
    sqlite3_bind_int(statement, 3, Int32(record.verseNumber))
    sqlite3_bind_blob(statement, 4, (record.embedding as NSData).bytes, Int32(record.embedding.count), nil)
    sqlite3_bind_text(statement, 5, (record.model as NSString).utf8String, -1, nil)
    sqlite3_bind_int64(statement, 6, record.createdAt)

    let success = sqlite3_step(statement) == SQLITE_DONE
    sqlite3_finalize(statement)

    return success
}

// MARK: - Main Script

let arguments = CommandLine.arguments

// Check for help flag
if arguments.contains("-h") || arguments.contains("--help") {
    printUsage()
    exit(0)
}

// Validate arguments
guard arguments.count >= 3 else {
    print("❌ Missing required arguments")
    printUsage()
    exit(1)
}

let sourcePath = arguments[1]
let destinationPath = arguments[2]

// Expand tilde if present
func expandPath(_ path: String) -> String {
    if path.hasPrefix("~") {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: "~", with: homeDir)
    }
    return path
}

let expandedSourcePath = expandPath(sourcePath)
let expandedDestinationPath = expandPath(destinationPath)

print("🔄 ViewTheWord Embeddings Migration")
print("=" * 50)
print("")

// Validate source file exists
guard FileManager.default.fileExists(atPath: expandedSourcePath) else {
    print("❌ Source file not found: \(expandedSourcePath)")
    exit(1)
}

print("📖 Source: \(expandedSourcePath)")
print("💾 Destination: \(expandedDestinationPath)")
print("")

// Open source database
guard let sourceDb = openSourceDatabase(path: expandedSourcePath) else {
    exit(1)
}
defer { sqlite3_close(sourceDb) }
print("✅ Opened source database")

// Check for embeddings table
guard checkEmbeddingsTable(db: sourceDb) else {
    print("❌ No embeddings table found in source database")
    print("   Make sure you're using a Bible file that has embeddings")
    exit(1)
}
print("✅ Found embeddings table in source")

// Open/create destination database
guard let destDb = openDestinationDatabase(path: expandedDestinationPath) else {
    exit(1)
}
defer { sqlite3_close(destDb) }
print("✅ Created destination database")

// Create destination schema
guard createEmbeddingsTable(db: destDb) else {
    exit(1)
}
print("✅ Created embeddings table schema")

// Read all embeddings from source
print("\n📚 Reading embeddings from source...")
let embeddings = getAllEmbeddings(db: sourceDb)

guard !embeddings.isEmpty else {
    print("❌ No embeddings found in source database")
    exit(1)
}

print("✅ Found \(embeddings.count) embeddings to migrate")

// Migrate embeddings
print("\n🚀 Migrating embeddings...")
var migratedCount = 0
var failedCount = 0

for (index, embedding) in embeddings.enumerated() {
    if storeEmbedding(db: destDb, record: embedding) {
        migratedCount += 1
    } else {
        failedCount += 1
        print("⚠️  Failed to migrate embedding at \(embedding.bookNumber):\(embedding.chapterNumber):\(embedding.verseNumber)")
    }

    // Show progress every 1000 embeddings
    if (index + 1) % 1000 == 0 {
        let progress = Float(index + 1) / Float(embeddings.count) * 100
        print("   Progress: \(index + 1)/\(embeddings.count) (\(String(format: "%.1f", progress))%)")
    }
}

print("")
print("✨ Migration complete!")
print("   Migrated: \(migratedCount) embeddings")
if failedCount > 0 {
    print("   Failed: \(failedCount) embeddings")
}
print("")
print("💡 Next steps:")
print("   1. Import \(URL(fileURLWithPath: expandedDestinationPath).lastPathComponent) in ViewTheWord (Settings → Bible → Import Embeddings)")
print("   2. You can now delete the old embeddings file and use any Bible translation with semantic search!")
