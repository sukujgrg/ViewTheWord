import SwiftUI
import UniformTypeIdentifiers
import SQLite3

struct SettingsView: View {
    private enum Tabs: Hashable {
        case general
        case font
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
    var body: some View {
        ContentUnavailableView(
            "No General Settings",
            systemImage: "gearshape",
            description: Text("General app options are currently not required.")
        )
    }
}

struct DisplaySettingsView: View {
    @AppStorage("fontSizeVerse") private var fontSizeVerse = 100.0
    @AppStorage("fontSizeVerseRef") private var fontSizeVerseRef = 20.0
    @AppStorage("vStackPadding") private var vStackPadding = 20.0
    @AppStorage("transparentBackground") var transparentBackground = false
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

                Section(header: Text("Background")) {
                    Toggle("Transparent background", isOn: $transparentBackground)
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

struct BibleImportView: View {
    @State private var isImporting: Bool = false
    @State private var importStatus: ImportStatus?
    @State private var showStatusAlert = false
    @State private var availableBibleUrls: [URL] = []

    @AppStorage("PrimaryBibleName") private var primaryBibleName: String = bundledPrimaryBibleUrl?.absoluteString ?? ""
    @AppStorage("SecondaryBibleName") private var secondaryBibleName: String = bundledSecondaryBibleUrl?.absoluteString ?? ""
    @AppStorage("showOnlyPrimary") var showOnlyPrimary = false

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

            Divider()
                .padding(.vertical, 8)

            HStack {
                Picker(selection: $primaryBibleName, label: Text("Primary")) {
                    ForEach(availableBibleUrls, id: \.absoluteString) { name in
                        Text(String(name.lastPathComponent))
                            .tag(name.absoluteString)
                    }
                }
                Divider()
                Picker(selection: $secondaryBibleName, label: Text("Secondary")) {
                    ForEach(availableBibleUrls, id: \.absoluteString) { name in
                        Text(name.lastPathComponent)
                            .tag(name.absoluteString)
                    }
                }
                .disabled(showOnlyPrimary)
            }
            .pickerStyle(.radioGroup)
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

        logger.info("Successfully imported Bible: \(fileName)")
        await MainActor.run {
            refreshAvailableBibles()
        }
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

    private func refreshAvailableBibles() {
        availableBibleUrls = BibleUrl().getAvailableBibleUrls()
    }
}
