import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import SQLite3

struct SettingsView: View {
    private enum Tabs: Hashable {
        case general
        case font
        case semanticSearch
        case bible
    }

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(Tabs.general)
            DisplaySettingsView()
                .tabItem {
                    Label("Display", systemImage: "display")
                }
                .tag(Tabs.font)
            SemanticSearchSettingsView()
                .tabItem {
                    Label("Semantic Search", systemImage: "brain")
                }
                .tag(Tabs.semanticSearch)
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

struct GeneralSettingsView: View {
    @AppStorage("history") private var history: [String] = ["John 3 16"]

    var body: some View {
        VStack {
            List {
                Section(header: Text("History")) {
                    Button("Clear History") {
                        history.removeAll()
                    }
                    .accessibilityLabel("Clear verse search history")
                    .accessibilityHint("Removes all previously searched verses from history")
                }
                .headerProminence(.increased)

                Section(header: Text("Debug Logs")) {
                    HStack {
                        Text(FileLogger.shared.getLogPath())
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Spacer()
                    }

                    HStack {
                        Button("Open Log File") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: FileLogger.shared.getLogPath()))
                        }

                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(
                                FileLogger.shared.getLogPath(),
                                inFileViewerRootedAtPath: ""
                            )
                        }

                        Button("Clear Logs") {
                            FileLogger.shared.clearLog()
                        }
                    }
                }
                .headerProminence(.increased)
            }
            .listStyle(.inset)
        }
    }
}

struct DisplaySettingsView: View {
    @AppStorage("fontSizeVerse") private var fontSizeVerse = 100.0
    @AppStorage("fontSizeVerseRef") private var fontSizeVerseRef = 20.0
    @AppStorage("vStackPadding") private var vStackPadding = 20.0
    @AppStorage("transparentBackground") var transparentBackground = false
    @AppStorage("apiUrlToPost") var apiUrlToPost: URL?

    var body: some View {
        VStack {
            List {
                Section(header: Text("Font Size")) {
                    Slider(value: $fontSizeVerse, in: 40 ... 200) {
                        Text("Verse (\(fontSizeVerse, specifier: "%.0f") pts)")
                    }
                    Slider(value: $fontSizeVerseRef, in: 20 ... 50) {
                        Text("Verse reference (\(fontSizeVerseRef, specifier: "%.0f") pts)")
                    }
                    Slider(value: $vStackPadding, in: 10 ... 200) {
                        Text("Padding (\(vStackPadding, specifier: "%.0f") pts)")
                    }
                }
                .headerProminence(.increased)

                Section(header: Text("Background")) {
                    Toggle("Transparent background", isOn: $transparentBackground)
                }
                .headerProminence(.increased)

                Section(header: Text("API to POST verse")) {
                    TextField("API URL", text: Binding(
                            get: { apiUrlToPost?.absoluteString ?? "" },
                            set: { apiUrlToPost = URL(string: $0) }
                    )).textFieldStyle(.roundedBorder)
                }
            }
            .listStyle(.inset)
        }
    }
}

struct SemanticSearchSettingsView: View {
    @KeychainStorage("OpenAIAPIKey") private var openAIAPIKey: String = ""
    @AppStorage("semanticSearchMinSimilarity") private var minSimilarity = 0.35
    @AppStorage("EmbeddingsDbPath") private var embeddingsDbPath: String = ""

    @State private var isImportingEmbeddings: Bool = false
    @State private var importStatus: ImportStatus?
    @State private var showStatusAlert = false

    let bibleType = UTType(exportedAs: "com.viewtheword.sqlite3.database", conformingTo: .database)

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
        VStack {
            List {
                Section(header: Text("OpenAI API Key")) {
                    SecureField("OpenAI API Key", text: $openAIAPIKey)
                        .textFieldStyle(.roundedBorder)
                    Text("Required for semantic/vector search. Get your key at platform.openai.com")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .headerProminence(.increased)

                Section(header: Text("Search Settings")) {
                    Slider(value: $minSimilarity, in: 0.2 ... 0.7, step: 0.05) {
                        Text("Min Similarity (\(minSimilarity, specifier: "%.2f"))")
                    }
                    Text("Higher values = stricter matches, fewer results")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .headerProminence(.increased)

                Section(header: Text("Embeddings Database")) {
                    Button(action: { isImportingEmbeddings = true }) {
                        Label("Import Embeddings", systemImage: "square.and.arrow.down")
                    }
                    .help("Import embeddings database for semantic search")
                    .fileImporter(
                        isPresented: $isImportingEmbeddings,
                        allowedContentTypes: [bibleType, .database, .data],
                        allowsMultipleSelection: false
                    ) { result in
                        Task {
                            await handleEmbeddingsImport(result: result)
                        }
                    }

                    if !embeddingsDbPath.isEmpty {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(URL(fileURLWithPath: embeddingsDbPath).lastPathComponent)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(action: { clearEmbeddings() }) {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Remove embeddings database")
                        }
                        Text("Semantic search is enabled")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("No embeddings imported")
                            Spacer()
                        }
                        Text("Import embeddings database above to enable semantic search")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .headerProminence(.increased)

                Section(header: Text("How to Use")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Search by meaning using the v: prefix:")
                            .font(.caption)
                        Text("v: verses about forgiveness")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("v: God's love for humanity")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("v: nt: salvation through faith")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .headerProminence(.increased)
            }
            .listStyle(.inset)
        }
        .alert(isPresented: $showStatusAlert) {
            Alert(
                title: Text(importStatus?.isSuccess ?? false ? "Success" : "Error"),
                message: Text(importStatus?.message ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: - Import Handler

    private func handleEmbeddingsImport(result: Result<[URL], Error>) async {
        do {
            guard let selectedFile = try result.get().first else { return }

            // Request security-scoped access
            guard selectedFile.startAccessingSecurityScopedResource() else {
                await showStatus(.failure("Permission denied to access file"))
                return
            }
            defer { selectedFile.stopAccessingSecurityScopedResource() }

            // Validate and import
            try await validateAndImportEmbeddings(selectedFile: selectedFile)

        } catch {
            await showStatus(.failure("Import failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Validation & Import

    private func validateAndImportEmbeddings(selectedFile: URL) async throws {
        let fileName = selectedFile.lastPathComponent

        // Validate it's a SQLite database
        guard await isSQLiteDatabase(url: selectedFile) else {
            await showStatus(.failure("\(fileName) is not a valid SQLite database"))
            return
        }

        // Validate embeddings schema
        guard await hasEmbeddingsSchema(url: selectedFile) else {
            await showStatus(.failure("\(fileName) does not contain valid embeddings data\n\nGenerate embeddings using:\nswift Scripts/GenerateEmbeddings.swift"))
            return
        }

        // Get embedding count for feedback
        let count = await getEmbeddingCount(url: selectedFile)

        // Copy to documents directory (replace if exists)
        let destURL = try await getDocumentsURL(fileName: fileName)

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
            logger.fileInfo("Removed existing embeddings file: \(fileName)")
        }

        try FileManager.default.copyItem(at: selectedFile, to: destURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destURL.path)

        // Update AppStorage
        await MainActor.run {
            embeddingsDbPath = destURL.path
        }

        logger.fileInfo("Successfully imported embeddings: \(fileName) with \(count) verses")
        await showStatus(.success("Successfully imported \(count) verse embeddings"))
    }

    // MARK: - Validation Helpers

    private func isSQLiteDatabase(url: URL) async -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fileHandle.close() }

        guard let header = try? fileHandle.read(upToCount: 16) else { return false }
        let sqliteHeader = "SQLite format 3\0".data(using: .utf8)

        return header == sqliteHeader
    }

    private func hasEmbeddingsSchema(url: URL) async -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }

        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }

        // Check for embeddings table with correct schema
        let query = """
            SELECT name FROM sqlite_master
            WHERE type='table' AND name='embeddings'
            AND sql LIKE '%book_number%' AND sql LIKE '%chapter_number%' AND sql LIKE '%verse_number%' AND sql LIKE '%embedding%';
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        return sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK &&
               sqlite3_step(statement) == SQLITE_ROW
    }

    private func getEmbeddingCount(url: URL) async -> Int {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }

        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return 0
        }

        let query = "SELECT COUNT(*) FROM embeddings;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    private func getDocumentsURL(fileName: String) async throws -> URL {
        let docDir = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return docDir.appendingPathComponent(fileName)
    }

    // MARK: - UI Helpers

    private func showStatus(_ status: ImportStatus) async {
        await MainActor.run {
            importStatus = status
            showStatusAlert = true
        }
    }

    private func clearEmbeddings() {
        if !embeddingsDbPath.isEmpty {
            embeddingsDbPath = ""
            logger.fileInfo("Cleared embeddings database")
            importStatus = .success("Embeddings database removed")
            showStatusAlert = true
        }
    }
}

struct BibleImportView: View {
    @State private var isImporting: Bool = false
    @State private var importStatus: ImportStatus?
    @State private var showStatusAlert = false

    @AppStorage("PrimaryBibleName") private var primaryBibleName: String = bundledPrimaryBibleUrl?.absoluteString ?? ""
    @AppStorage("SecondaryBibleName") private var secondaryBibleName: String = bundledSecondaryBibleUrl?.absoluteString ?? ""
    @AppStorage("showOnlyPrimary") var showOnlyPrimary = false
    @AppStorage("scrollTo") var scrollTo = true

    let bibleType = UTType(exportedAs: "com.viewtheword.sqlite3.database", conformingTo: .database)

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
        VStack {
            Button(action: { isImporting = true }) {
                Label("Import Bible", systemImage: "book.circle")
            }
            .help("Import a Bible translation (.bible file)")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [bibleType, .database, .data],
                allowsMultipleSelection: false
            ) { result in
                Task {
                    await handleBibleImport(result: result)
                }
            }

            Divider()
                .padding(.vertical, 8)

            Toggle("Show only Primary Verse", isOn: $showOnlyPrimary)
            Toggle("Scroll to the current verse automatically", isOn: $scrollTo)

            Divider()
                .padding(.vertical, 8)

            HStack {
                Picker(selection: $primaryBibleName, label: Text("Primary")) {
                    ForEach(BibleUrl().getAvailableBibleUrls(), id: \.absoluteString) { name in
                        Text(String(name.lastPathComponent))
                    }
                }.onChange(of: primaryBibleName) { _, name in
                    primaryBibleName = name
                }
                Divider()
                Picker(selection: $secondaryBibleName, label: Text("Secondary")) {
                    ForEach(BibleUrl().getAvailableBibleUrls(), id: \.absoluteString) { name in
                        Text(name.lastPathComponent)
                    }
                }.onChange(of: secondaryBibleName) { _, name in
                    secondaryBibleName = name
                }
                .disabled(showOnlyPrimary)
            }
            .pickerStyle(.radioGroup)
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

    private func handleBibleImport(result: Result<[URL], Error>) async {
        do {
            guard let selectedFile = try result.get().first else { return }

            // Request security-scoped access
            guard selectedFile.startAccessingSecurityScopedResource() else {
                await showStatus(.failure("Permission denied to access file"))
                return
            }
            defer { selectedFile.stopAccessingSecurityScopedResource() }

            // Validate file
            try await validateAndImportBible(selectedFile: selectedFile)

        } catch {
            await showStatus(.failure("Import failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Validation & Import

    private func validateAndImportBible(selectedFile: URL) async throws {
        let fileName = selectedFile.lastPathComponent

        // Validate filename format
        guard isValidBibleFileName(fileName: fileName) else {
            await showStatus(.failure("Invalid filename. Expected format: <LANG>_<NAME>.bible\nExample: ENG_UKJV.bible"))
            return
        }

        // Validate it's a SQLite database
        guard await isSQLiteDatabase(url: selectedFile) else {
            await showStatus(.failure("\(fileName) is not a valid SQLite database"))
            return
        }

        // Validate Bible schema
        guard await hasBibleSchema(url: selectedFile) else {
            await showStatus(.failure("\(fileName) does not have the required Bible schema"))
            return
        }

        // Check for bundled Bibles
        let bundledNames = [bundledPrimaryBibleUrl?.lastPathComponent, bundledSecondaryBibleUrl?.lastPathComponent].compactMap { $0 }
        if bundledNames.contains(fileName) {
            await showStatus(.failure("Cannot import bundled Bible: \(fileName)"))
            return
        }

        // Copy to documents directory
        let destURL = try await getDocumentsURL(fileName: fileName)

        if FileManager.default.fileExists(atPath: destURL.path) {
            await showStatus(.failure("Bible file already exists: \(fileName)"))
            return
        }

        try FileManager.default.copyItem(at: selectedFile, to: destURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destURL.path)

        logger.fileInfo("Successfully imported Bible: \(fileName)")
        await showStatus(.success("Successfully imported \(fileName)"))
    }

    // MARK: - Validation Helpers

    private func isValidBibleFileName(fileName: String) -> Bool {
        fileName.range(of: #"\b[A-Z]{3}_[A-Z]{3,6}\.bible\b"#, options: .regularExpression) != nil
    }

    private func isSQLiteDatabase(url: URL) async -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fileHandle.close() }

        guard let header = try? fileHandle.read(upToCount: 16) else { return false }
        let sqliteHeader = "SQLite format 3\0".data(using: .utf8)

        return header == sqliteHeader
    }

    private func hasBibleSchema(url: URL) async -> Bool {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }

        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return false
        }

        // Check for required table and columns
        let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='bible';"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        return sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK &&
               sqlite3_step(statement) == SQLITE_ROW
    }

    private func getDocumentsURL(fileName: String) async throws -> URL {
        let docDir = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return docDir.appendingPathComponent(fileName)
    }

    // MARK: - UI Helpers

    private func showStatus(_ status: ImportStatus) async {
        await MainActor.run {
            importStatus = status
            showStatusAlert = true
        }
    }
}
