#!/usr/bin/swift
//
// GenerateEmbeddings.swift
// Script to generate OpenAI embeddings for Bible verses in a standalone embeddings database
//
// Usage:
//   1. Set OPENAI_API_KEY environment variable (or create ~/.openai_key file)
//   2. Run with Bible file path and output embeddings file path:
//      swift GenerateEmbeddings.swift /path/to/ENG_UKJV.bible /path/to/embeddings.bible
//
//   Or run with just Bible path (creates embeddings.bible in same directory):
//      swift GenerateEmbeddings.swift /path/to/ENG_UKJV.bible
//
// Cost estimate: ~$0.03 for text-embedding-3-small (31,000 verses)
//

import Foundation
import SQLite3

let BATCH_SIZE = 100  // Process 100 verses at a time
let MODEL = "text-embedding-3-small"  // 1536 dimensions

// MARK: - OpenAI API Structures

struct EmbeddingRequest: Codable {
    let model: String
    let input: [String]
}

struct EmbeddingResponse: Codable {
    let data: [EmbeddingData]

    struct EmbeddingData: Codable {
        let embedding: [Float]
        let index: Int
    }
}

// MARK: - Helper Functions

func printUsage() {
    print("""

    Usage:
      swift GenerateEmbeddings.swift BIBLE_FILE_PATH [EMBEDDINGS_OUTPUT_PATH]

    Arguments:
      BIBLE_FILE_PATH           Path to source Bible SQLite file (e.g., ENG_UKJV.bible)
      EMBEDDINGS_OUTPUT_PATH    Optional path for output embeddings database
                                If not provided, creates 'embeddings.bible' in same directory as Bible file

    Examples:
      # Create embeddings.bible in ViewTheWord directory
      swift GenerateEmbeddings.swift ViewTheWord/ENG_UKJV.bible

      # Specify output path
      swift GenerateEmbeddings.swift ~/Downloads/ENG_UKJV.bible ~/Documents/embeddings.bible

      # Get help
      swift GenerateEmbeddings.swift --help

    Requirements:
      - Set OPENAI_API_KEY environment variable, or
      - Create ~/.openai_key file with your API key

    Output:
      Creates a standalone embeddings.db file that works with ANY Bible translation

    """)
}

func loadAPIKey() -> String? {
    // Try environment variable first
    if let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty {
        return apiKey
    }

    // Try reading from .openai_key file in home directory
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let envPath = homeDir.appendingPathComponent(".openai_key")

    if let contents = try? String(contentsOf: envPath, encoding: .utf8) {
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return nil
}

func getPaths() -> (biblePath: String, embeddingsPath: String)? {
    let arguments = CommandLine.arguments

    // If path provided as argument, use it
    if arguments.count >= 2 {
        let providedBiblePath = arguments[1]

        // Expand tilde if present
        let expandedBiblePath: String
        if providedBiblePath.hasPrefix("~") {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
            expandedBiblePath = providedBiblePath.replacingOccurrences(of: "~", with: homeDir)
        } else {
            expandedBiblePath = providedBiblePath
        }

        // Check if Bible file exists
        guard FileManager.default.fileExists(atPath: expandedBiblePath) else {
            print("❌ Bible file not found: \(expandedBiblePath)")
            return nil
        }

        // Determine embeddings output path
        let embeddingsPath: String
        if arguments.count >= 3 {
            // User provided embeddings path
            let providedEmbeddingsPath = arguments[2]
            if providedEmbeddingsPath.hasPrefix("~") {
                let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
                embeddingsPath = providedEmbeddingsPath.replacingOccurrences(of: "~", with: homeDir)
            } else {
                embeddingsPath = providedEmbeddingsPath
            }
        } else {
            // Create embeddings.db in same directory as Bible file
            let bibleUrl = URL(fileURLWithPath: expandedBiblePath)
            let bibleDir = bibleUrl.deletingLastPathComponent()
            embeddingsPath = bibleDir.appendingPathComponent("embeddings.db").path
        }

        return (biblePath: expandedBiblePath, embeddingsPath: embeddingsPath)
    }

    return nil
}

// MARK: - OpenAI API

func generateEmbeddings(texts: [String], apiKey: String) async throws -> [[Float]] {
    let url = URL(string: "https://api.openai.com/v1/embeddings")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")

    let body = EmbeddingRequest(model: MODEL, input: texts)
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
        throw NSError(domain: "OpenAI", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                     userInfo: [NSLocalizedDescriptionKey: errorBody])
    }

    let embeddingResponse = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
    return embeddingResponse.data.sorted { $0.index < $1.index }.map { $0.embedding }
}

// MARK: - Database Operations

struct VerseCoordinate {
    let bookNumber: Int
    let chapterNumber: Int
    let verseNumber: Int
    let text: String
}

func openBibleDatabase(path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
        print("❌ Failed to open Bible database at: \(path)")
        return nil
    }
    return db
}

func openEmbeddingsDatabase(path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) != SQLITE_OK {
        print("❌ Failed to create embeddings database at: \(path)")
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
        print("❌ Failed to create embeddings table")
        return false
    }

    return true
}

func getAllVerses(db: OpaquePointer) -> [VerseCoordinate] {
    var verses: [VerseCoordinate] = []
    let query = "SELECT bnumber, cnumber, vnumber, verse FROM bible ORDER BY id;"
    var statement: OpaquePointer?

    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        print("❌ Failed to prepare verses query")
        return []
    }

    while sqlite3_step(statement) == SQLITE_ROW {
        let bookNumber = Int(sqlite3_column_int(statement, 0))
        let chapterNumber = Int(sqlite3_column_int(statement, 1))
        let verseNumber = Int(sqlite3_column_int(statement, 2))

        if let textPtr = sqlite3_column_text(statement, 3) {
            let text = String(cString: textPtr)
            verses.append(VerseCoordinate(
                bookNumber: bookNumber,
                chapterNumber: chapterNumber,
                verseNumber: verseNumber,
                text: text
            ))
        }
    }

    sqlite3_finalize(statement)
    return verses
}

func storeEmbedding(db: OpaquePointer, verse: VerseCoordinate, embedding: [Float]) -> Bool {
    let query = """
        INSERT OR REPLACE INTO embeddings (book_number, chapter_number, verse_number, embedding, model, created_at)
        VALUES (?, ?, ?, ?, ?, ?);
    """
    var statement: OpaquePointer?

    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
        return false
    }

    // Convert embedding to Data
    let embeddingData = Data(bytes: embedding, count: embedding.count * MemoryLayout<Float>.size)

    sqlite3_bind_int(statement, 1, Int32(verse.bookNumber))
    sqlite3_bind_int(statement, 2, Int32(verse.chapterNumber))
    sqlite3_bind_int(statement, 3, Int32(verse.verseNumber))
    sqlite3_bind_blob(statement, 4, (embeddingData as NSData).bytes, Int32(embeddingData.count), nil)
    sqlite3_bind_text(statement, 5, (MODEL as NSString).utf8String, -1, nil)
    sqlite3_bind_int64(statement, 6, Int64(Date().timeIntervalSince1970))

    let success = sqlite3_step(statement) == SQLITE_DONE
    sqlite3_finalize(statement)

    return success
}

func *(string: String, count: Int) -> String {
    return String(repeating: string, count: count)
}

// MARK: - Main Script

Task {
    // Check for help flag first (before printing banner)
    let arguments = CommandLine.arguments
    if arguments.contains("-h") || arguments.contains("--help") {
        printUsage()
        exit(0)
    }

    print("🔮 ViewTheWord Embedding Generator")
    print("=" * 50)
    print("")

    // Load API key
    guard let apiKey = loadAPIKey() else {
        print("❌ OpenAI API key not found!")
        print("")
        print("   Option 1: Set environment variable")
        print("   export OPENAI_API_KEY='sk-your-key-here'")
        print("")
        print("   Option 2: Create ~/.openai_key file")
        print("   echo 'sk-your-key-here' > ~/.openai_key")
        print("")
        print("   Get your key at: https://platform.openai.com")
        exit(1)
    }
    print("✅ API key loaded")

    // Get Bible and embeddings paths
    guard let paths = getPaths() else {
        print("")
        print("💡 Usage: swift GenerateEmbeddings.swift BIBLE_FILE_PATH [EMBEDDINGS_OUTPUT_PATH]")
        print("   Run with --help for more information")
        exit(1)
    }

    print("✅ Source Bible: \(paths.biblePath)")
    print("✅ Output embeddings: \(paths.embeddingsPath)")
    print("")

    // Open Bible database (read-only)
    guard let bibleDb = openBibleDatabase(path: paths.biblePath) else {
        exit(1)
    }
    defer { sqlite3_close(bibleDb) }
    print("✅ Bible database opened")

    // Open/create embeddings database
    guard let embeddingsDb = openEmbeddingsDatabase(path: paths.embeddingsPath) else {
        exit(1)
    }
    defer { sqlite3_close(embeddingsDb) }
    print("✅ Embeddings database ready")

    // Create embeddings table
    guard createEmbeddingsTable(db: embeddingsDb) else {
        exit(1)
    }
    print("✅ Embeddings table created")

    // Get all verses
    let verses = getAllVerses(db: bibleDb)
    print("✅ Found \(verses.count) verses")

    // Check for existing embeddings
    var existingCount = 0
    let countQuery = "SELECT COUNT(*) FROM embeddings;"
    var statement: OpaquePointer?
    if sqlite3_prepare_v2(embeddingsDb, countQuery, -1, &statement, nil) == SQLITE_OK {
        if sqlite3_step(statement) == SQLITE_ROW {
            existingCount = Int(sqlite3_column_int(statement, 0))
        }
        sqlite3_finalize(statement)
    }

    if existingCount > 0 {
        print("⚠️  Found \(existingCount) existing embeddings")
        print("   Continuing will overwrite them. Press Ctrl+C to cancel, Enter to continue...")
        _ = readLine()
    }

    // Process in batches
    print("\n🚀 Generating embeddings...")
    print("   Model: \(MODEL)")
    print("   Batch size: \(BATCH_SIZE)")
    print("   Estimated cost: ~$0.03")
    print("")

    let totalBatches = (verses.count + BATCH_SIZE - 1) / BATCH_SIZE
    var processedVerses = 0

    for batchIndex in 0..<totalBatches {
        let start = batchIndex * BATCH_SIZE
        let end = min(start + BATCH_SIZE, verses.count)
        let batch = Array(verses[start..<end])

        let texts = batch.map { $0.text }

        do {
            // Generate embeddings for batch
            let embeddings = try await generateEmbeddings(texts: texts, apiKey: apiKey)

            // Store embeddings with verse coordinates
            for (index, embedding) in embeddings.enumerated() {
                let verse = batch[index]
                if !storeEmbedding(db: embeddingsDb, verse: verse, embedding: embedding) {
                    print("⚠️  Failed to store embedding for \(verse.bookNumber):\(verse.chapterNumber):\(verse.verseNumber)")
                }
            }

            processedVerses += batch.count
            let progress = Float(processedVerses) / Float(verses.count) * 100
            print("✅ Batch \(batchIndex + 1)/\(totalBatches) - \(processedVerses)/\(verses.count) verses (\(String(format: "%.1f", progress))%)")

            // Small delay to avoid rate limits
            if batchIndex < totalBatches - 1 {
                try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            }

        } catch {
            print("❌ Error processing batch \(batchIndex + 1): \(error.localizedDescription)")
            exit(1)
        }
    }

    print("\n✨ Done! Generated embeddings for \(processedVerses) verses")
    print("   Output: \(paths.embeddingsPath)")
    print("   This embeddings file works with ANY Bible translation!")
    print("   Import it in ViewTheWord settings to enable semantic search.")
    exit(0)
}

// Keep script alive until Task completes
RunLoop.main.run()
