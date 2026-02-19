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
    @AppStorage("fontSizeVerseRef") private var fontSizeVerseRef = 20.0
    @AppStorage("vStackPadding") private var vStackPadding = 20.0
    @AppStorage(AppDefaultsKey.apiUrlToPost) private var apiUrlToPost = ""
    @State private var apiUrlDraft = ""

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

                Section(header: Text("API to POST verse")) {
                    TextField("API URL", text: $apiUrlDraft)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiUrlDraft) { _, newValue in
                            persistAPIURLIfValid(newValue)
                        }

                    if !apiUrlDraft.isEmpty && !isValidAPIURL(apiUrlDraft) {
                        Text("Enter a valid http(s) URL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
        .onAppear {
            if apiUrlToPost.isEmpty, let legacyURL = UserDefaults.standard.url(forKey: AppDefaultsKey.apiUrlToPost) {
                apiUrlToPost = legacyURL.absoluteString
            }
            apiUrlDraft = apiUrlToPost
        }
    }

    private func persistAPIURLIfValid(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isValidAPIURL(trimmed) {
            apiUrlToPost = trimmed
        }
    }

    private func isValidAPIURL(_ rawValue: String) -> Bool {
        guard let url = URL(string: rawValue) else { return false }
        guard let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") else {
            return false
        }
        return url.host != nil
    }
}

private enum BibleImportError: LocalizedError {
    case invalidFileName
    case invalidSQLiteDatabase(String)
    case invalidBibleSchema(String)
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
                    Text("Book name column is not required; app maps `bnumber` to canonical book names.")
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
