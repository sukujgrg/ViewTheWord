import SwiftUI
import UniformTypeIdentifiers
import SQLite3

struct SettingsView: View {
    private enum Tabs: Hashable {
        case font
        case bible
    }

    var body: some View {
        TabView {
            DisplaySettingsView()
                .tabItem {
                    Label("Display", systemImage: "display")
                }
                .tag(Tabs.font)
            BibleImportView()
                .tabItem {
                    Label("Bible", systemImage: "book")
                }
                .tag(Tabs.bible)
        }
        .padding(20)
        .frame(width: 500, height: 400)
    }
}

struct DisplaySettingsView: View {
    @AppStorage("fontSizeVerse") private var fontSizeVerse = 100.0
    @AppStorage("fontSizeVerseRef") private var fontSizeVerseRef = 36.0
    @AppStorage("vStackPadding") private var vStackPadding = 20.0

    @State private var fontSizeVerseDraft = 100.0
    @State private var fontSizeVerseRefDraft = 36.0
    @State private var vStackPaddingDraft = 20.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Font Size") {
                VStack(alignment: .leading, spacing: 14) {
                    sliderRow(
                        title: "Verse",
                        valueText: String(format: "%.0f pts", fontSizeVerseDraft)
                    )
                    Slider(value: $fontSizeVerseDraft, in: 40 ... 200, step: 1, onEditingChanged: { isEditing in
                        if !isEditing {
                            persistFontSettings()
                        }
                    })

                    sliderRow(
                        title: "Verse reference",
                        valueText: String(format: "%.0f pts", fontSizeVerseRefDraft)
                    )
                    Slider(value: $fontSizeVerseRefDraft, in: 20 ... 72, step: 1, onEditingChanged: { isEditing in
                        if !isEditing {
                            persistFontSettings()
                        }
                    })

                    sliderRow(
                        title: "Padding",
                        valueText: String(format: "%.0f pts", vStackPaddingDraft)
                    )
                    Slider(value: $vStackPaddingDraft, in: 10 ... 200, step: 1, onEditingChanged: { isEditing in
                        if !isEditing {
                            persistFontSettings()
                        }
                    })
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 4)
        .onAppear {
            fontSizeVerseDraft = fontSizeVerse
            fontSizeVerseRefDraft = fontSizeVerseRef
            vStackPaddingDraft = vStackPadding
        }
        .onDisappear {
            persistFontSettings()
        }
    }

    private func persistFontSettings() {
        if fontSizeVerse != fontSizeVerseDraft {
            fontSizeVerse = fontSizeVerseDraft
        }

        if fontSizeVerseRef != fontSizeVerseRefDraft {
            fontSizeVerseRef = fontSizeVerseRefDraft
        }

        if vStackPadding != vStackPaddingDraft {
            vStackPadding = vStackPaddingDraft
        }
    }

    @ViewBuilder
    private func sliderRow(title: String, valueText: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(valueText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }
}

private enum BibleImportError: LocalizedError {
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

private actor BibleImportService {
    func importBible(selectedFile: URL, bundledBibleNames: Set<String>) throws -> URL {
        let fileName = selectedFile.lastPathComponent

        guard BibleFileRule.isValidFileName(fileName) else {
            throw BibleImportError.invalidFileName
        }

        guard isSQLiteDatabase(url: selectedFile) else {
            throw BibleImportError.invalidSQLiteDatabase(fileName)
        }

        guard hasBibleSchema(url: selectedFile) else {
            throw BibleImportError.invalidBibleSchema(fileName)
        }

        if let compatibilityError = canonicalCompatibilityError(url: selectedFile, fileName: fileName) {
            throw compatibilityError
        }

        guard !bundledBibleNames.contains(fileName) else {
            throw BibleImportError.bundledBibleImportBlocked(fileName)
        }

        let destinationURL = try destinationURL(for: fileName)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw BibleImportError.bibleAlreadyExists(fileName)
        }

        return try copyBibleFileAtomically(from: selectedFile, to: destinationURL)
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

    private func copyBibleFileAtomically(from sourceURL: URL, to destinationURL: URL) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).import", isDirectory: false)

        var cleanupTemporary = false
        defer {
            if cleanupTemporary {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        cleanupTemporary = true

        setReadOnlyPermissionsIfPossible(for: temporaryURL)

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        cleanupTemporary = false

        setReadOnlyPermissionsIfPossible(for: destinationURL)
        return destinationURL
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
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_close(db) }

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
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return .incompatibleBible("\(fileName) cannot be validated for canonical book compatibility.")
        }
        defer { sqlite3_close(db) }

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

struct BibleImportView: View {
    @State private var isImporting: Bool = false
    @State private var isImportInProgress = false
    @State private var importStatus: ImportStatus?
    @State private var showStatusAlert = false
    @State private var availableBibleUrls: [URL] = []

    let bibleType = UTType(exportedAs: "com.viewtheword.sqlite3.database", conformingTo: .database)
    private static let importService = BibleImportService()

    enum ImportStatus {
        case success(String)
        case failure(String)

        var message: String {
            switch self {
            case .success(let msg): return msg
            case .failure(let msg): return msg
            }
        }

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: { isImporting = true }) {
                    Label("Import Bible", systemImage: "book.circle")
                }
                .disabled(isImportInProgress)
                .help("Import a Bible translation (.bible file)")
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: [bibleType, .database],
                    allowsMultipleSelection: false
                ) { result in
                    Task {
                        await handleBibleImport(result: result)
                    }
                }
                Spacer()
            }

            List {
                Section("Valid Bible Criteria") {
                    Text("File name must match: `<LANG>_<NAME>.bible` (example: `ENG_UKJV.bible`).")
                    Text("File must be a valid SQLite database.")
                    Text("Database must contain table `bible` with columns:")
                    Text("`\(BibleFileRule.requiredBibleColumns.sorted().joined(separator: ", "))`")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Database must include table `bnames` with 66 entries.")
                    Text("`bnumber` must cover canonical books 1...66.")
                    Text("Chapter coverage must match canonical boundaries for each `bnumber`.")
                    Text("Book name column in `bible` table is not required; app maps by `bnumber`.")
                    Text("Bundled Bible files cannot be imported again.")
                }

                Section("Available Bibles") {
                    if availableBibleUrls.isEmpty {
                        Text("No available Bible files found.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(availableBibleUrls, id: \.absoluteString) { url in
                            Text(url.lastPathComponent)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .onAppear {
            refreshAvailableBibles()
        }
        .alert(isPresented: $showStatusAlert) {
            Alert(
                title: Text(importStatus?.isSuccess ?? false ? "Success" : "Error"),
                message: Text(importStatus?.message ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Import Handlers

    @MainActor
    private func handleBibleImport(result: Result<[URL], Error>) async {
        guard !isImportInProgress else { return }
        isImportInProgress = true
        defer { isImportInProgress = false }

        do {
            guard let selectedFile = try result.get().first else { return }

            let hasScopedAccess = selectedFile.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    selectedFile.stopAccessingSecurityScopedResource()
                }
            }

            let bundledNames = Set(
                [bundledPrimaryBibleUrl?.lastPathComponent, bundledSecondaryBibleUrl?.lastPathComponent]
                    .compactMap { $0 }
            )
            let importedURL = try await Self.importService.importBible(
                selectedFile: selectedFile,
                bundledBibleNames: bundledNames
            )

            logger.info("Successfully imported Bible: \(importedURL.lastPathComponent)")
            BibleUrl.invalidateAvailableBibleUrlCache()
            refreshAvailableBibles()
            showStatus(.success("Successfully imported \(importedURL.lastPathComponent)"))
        } catch let error as CocoaError where error.code == .userCancelled {
            return
        } catch let error as BibleImportError {
            showStatus(.failure(error.localizedDescription))
        } catch {
            showStatus(.failure("Import failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - UI Helpers

    @MainActor
    private func showStatus(_ status: ImportStatus) {
        importStatus = status
        showStatusAlert = true
    }

    @MainActor
    private func refreshAvailableBibles() {
        availableBibleUrls = BibleUrl().getAvailableBibleUrls()
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}
