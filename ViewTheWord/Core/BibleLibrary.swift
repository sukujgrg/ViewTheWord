import Foundation
import Combine

enum BibleLibraryError: LocalizedError {
    case empty

    var errorDescription: String? {
        "No translations available. Import a Bible in Settings → Bible Library."
    }
}

@MainActor
final class BibleUrl {
    private static var cachedAvailableBibleUrls: [URL]?

    static func invalidateAvailableBibleUrlCache() {
        cachedAvailableBibleUrls = nil
    }

    func getAvailableBibleUrls(forceRefresh: Bool = false) -> [URL] {
        if !forceRefresh {
            let cachedUrls = Self.cachedAvailableBibleUrls
            if let cachedUrls {
                return cachedUrls
            }
        }

        let scannedUrls = scanAvailableBibleUrls()
        Self.cachedAvailableBibleUrls = scannedUrls
        return scannedUrls
    }

    private func scanAvailableBibleUrls() -> [URL] {
        var availableBibleUrls: [URL] = []

        if let primary = bundledPrimaryBibleUrl {
            availableBibleUrls.append(primary)
        }
        if let secondary = bundledSecondaryBibleUrl {
            availableBibleUrls.append(secondary)
        }

        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            logger.error("Could not access documents directory")
            return availableBibleUrls
        }

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
            let bibleDbUrls = fileURLs.filter {
                $0.pathExtension.lowercased() == BibleFileRule.fileExtension
                    && BibleFileRule.isValidFileName($0.lastPathComponent)
            }
            availableBibleUrls += bibleDbUrls
        } catch {
            logger.error("\(documentsURL.path): \(error.localizedDescription)")
        }
        var dedupedByFileName: [String: URL] = [:]
        for url in availableBibleUrls {
            dedupedByFileName[url.lastPathComponent] = url
        }

        return Array(dedupedByFileName.values)
    }
}


enum BibleTranslation {
    static func shortName(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        return parts.count == 2 ? String(parts[1]) : name
    }

    static func name(for url: URL) -> String {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_").map(String.init)
        guard parts.count == 2 else { return url.deletingPathExtension().lastPathComponent }
        let languages = ["ENG": "English", "MAL": "Malayalam", "TAM": "Tamil", "HIN": "Hindi", "TEL": "Telugu", "KAN": "Kannada", "ARA": "Arabic", "HEB": "Hebrew", "SPA": "Spanish", "FRA": "French"]
        return "\(languages[parts[0]] ?? parts[0]) · \(parts[1])"
    }
}

@MainActor
final class BibleLibrary: ObservableObject {
    static let shared = BibleLibrary()
    @Published private(set) var urls: [URL] = []
    @Published private(set) var revision = 0
    @Published private(set) var isImporting = false
    @Published private(set) var alerts: [LibraryAlert] = []
    private var claimedAlertIDs = Set<UUID>()
    private var importQueue: [ImportRequest] = []
    private var activeImport: ImportRequest?
    private var settingsPresented = false
    private let usesSuppliedCatalog: Bool
    private let catalogProvider: (() -> [URL])?
    private let importer: Importer

    /// A supplied catalog lets native fixtures use repository data without
    /// discovering translations in the operator's Documents directory.
    init(preloadedURLs: [URL]? = nil, catalogProvider: (() -> [URL])? = nil, importer: Importer? = nil) {
        let service = BibleImportService()
        self.importer = importer ?? { url, bundledNames, replaceExisting in
            try await service.importBible(selectedFile: url, bundledBibleNames: bundledNames, replaceExisting: replaceExisting)
        }
        usesSuppliedCatalog = preloadedURLs != nil
        self.catalogProvider = catalogProvider
        if let preloadedURLs {
            urls = preloadedURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
            revision = 1
        } else { refresh() }
    }
    func refresh() {
        if let catalogProvider {
            urls = catalogProvider().sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else if !usesSuppliedCatalog {
            BibleUrl.invalidateAvailableBibleUrlCache()
            urls = BibleUrl().getAvailableBibleUrls().sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        revision += 1
    }

    func sources(for translations: PassageTranslations) -> BibleSources? {
        func resolve(_ preference: URL?) -> URL? {
            guard let preference else { return nil }
            return urls.first { $0.lastPathComponent == preference.lastPathComponent }
        }
        // Fallbacks depend on the catalog, never another tab's saved preferences.
        // No available primary means there is no database to read.
        guard let first = resolve(translations.primary) ?? resolve(bundledPrimaryBibleUrl) ?? urls.first else { return nil }
        let second = resolve(translations.secondary) ?? resolve(bundledSecondaryBibleUrl)
            ?? urls.first(where: { $0 != first }) ?? first
        return BibleSources(primary: first, secondary: translations.primaryOnly ? nil : second, revision: revision)
    }

    func defaultTranslations(_ defaults: UserDefaults) -> PassageTranslations {
        func savedURL(_ key: String) -> URL? {
            guard let value = defaults.string(forKey: key), !value.isEmpty else { return nil }
            let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value)
            guard let url, url.isFileURL, BibleFileRule.isValidFileName(url.lastPathComponent) else { return nil }
            return url
        }
        let primary = savedURL(AppDefaultsKey.primaryBibleName) ?? bundledPrimaryBibleUrl ?? urls.first
        let secondary = savedURL(AppDefaultsKey.secondaryBibleName) ?? bundledSecondaryBibleUrl
            ?? urls.first(where: { $0 != primary }) ?? primary
        return PassageTranslations(primary: primary, secondary: secondary,
                                   primaryOnly: defaults.bool(forKey: AppDefaultsKey.showOnlyPrimary))
    }
}

extension BibleLibrary {
    enum Presenter { case main, settings }
    typealias Importer = @Sendable (URL, Set<String>, Bool) async throws -> URL

    struct LibraryAlert: Identifiable, Equatable {
        enum Content: Equatable { case notice(String), replacement(URL) }
        let id = UUID()
        let presenter: Presenter
        let content: Content
        var title: String {
            if case .replacement = content { return "Replace imported translation?" }
            return "Bible Library"
        }
        var message: String {
            switch content {
            case .notice(let message): return message
            case .replacement(let url):
                return "Replace \(url.lastPathComponent)? The existing copy remains intact if validation or import fails."
            }
        }
    }

    private final class ImportRequest {
        let url: URL
        let presenter: Presenter
        var permitsReplacementPrompt: Bool
        private let scoped: Bool
        init(url: URL, presenter: Presenter, permitsReplacementPrompt: Bool) {
            self.url = url
            self.presenter = presenter
            self.permitsReplacementPrompt = permitsReplacementPrompt
            // Retain access while queued and while awaiting a replacement decision.
            scoped = url.startAccessingSecurityScopedResource()
        }
        deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
    }

    func importFile(_ url: URL, presenter: Presenter) {
        importQueue.append(ImportRequest(url: url, presenter: presenter,
                                         permitsReplacementPrompt: presenter != .settings || settingsPresented))
        startNextImport()
    }

    func setSettingsPresented(_ presented: Bool) {
        settingsPresented = presented
        guard !presented else { return }
        // Closing Settings declines unresolved replacements, including imports
        // that have not finished validation yet. Ordinary imports still finish.
        if activeImport?.presenter == .settings { activeImport?.permitsReplacementPrompt = false }
        for request in importQueue where request.presenter == .settings { request.permitsReplacementPrompt = false }
        let replacements = alerts.compactMap { alert -> UUID? in
            guard alert.presenter == .settings, case .replacement = alert.content else { return nil }
            return alert.id
        }
        for id in replacements { completeAlert(id) }
    }

    private func startNextImport() {
        guard activeImport == nil, !importQueue.isEmpty else { return }
        let request = importQueue.removeFirst()
        activeImport = request
        runImport(request, replaceExisting: false)
    }

    private func runImport(_ request: ImportRequest, replaceExisting: Bool) {
        isImporting = true
        Task {
            do {
                let imported = try await importer(request.url, bundledNames, replaceExisting)
                if usesSuppliedCatalog {
                    urls.removeAll { $0.lastPathComponent == imported.lastPathComponent }
                    urls.append(imported)
                    urls.sort { $0.lastPathComponent < $1.lastPathComponent }
                }
                refresh()
                showNotice("Imported \(BibleTranslation.name(for: imported)). It is now available in the translation pickers.", presenter: request.presenter)
            } catch BibleImportError.bibleAlreadyExists {
                if request.permitsReplacementPrompt {
                    isImporting = false
                    enqueueAlert(LibraryAlert(presenter: request.presenter, content: .replacement(request.url)))
                    return
                }
                showNotice("Import canceled. The existing \(request.url.lastPathComponent) was kept.", presenter: request.presenter)
            } catch {
                showNotice("Could not import \(request.url.lastPathComponent): \(error.localizedDescription)", presenter: request.presenter)
            }
            finishImport()
        }
    }

    private func finishImport() {
        activeImport = nil
        isImporting = false
        startNextImport()
    }

    func showNotice(_ message: String, presenter: Presenter) {
        enqueueAlert(LibraryAlert(presenter: presenter, content: .notice(message)))
    }

    private func enqueueAlert(_ next: LibraryAlert) {
        alerts.append(next)
    }

    func alert(for presenter: Presenter) -> LibraryAlert? {
        // An unopened Settings window must not hide Finder import results.
        alerts.first { $0.presenter == presenter }
    }

    /// Native passage windows share the queue; only one may present each alert.
    func claimAlert(for presenter: Presenter) -> LibraryAlert? {
        guard let alert = alert(for: presenter), claimedAlertIDs.insert(alert.id).inserted else { return nil }
        return alert
    }

    func completeAlert(_ id: UUID, replaceExisting: Bool = false) {
        guard let index = alerts.firstIndex(where: { $0.id == id }) else { return }
        let current = alerts.remove(at: index)
        claimedAlertIDs.remove(id)
        if case .replacement(let url) = current.content, let request = activeImport, request.url == url {
            if replaceExisting { runImport(request, replaceExisting: true) }
            else { finishImport() }
        }
    }

    var bundledNames: Set<String> {
        Set([bundledPrimaryBibleUrl, bundledSecondaryBibleUrl].compactMap { $0?.lastPathComponent })
    }
    func isImported(_ url: URL) -> Bool {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        return urls.contains(url) && url.deletingLastPathComponent().standardizedFileURL == documents.standardizedFileURL
    }
    func removeImported(_ url: URL) {
        guard isImported(url) else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            refresh()
        } catch { showNotice("Could not move the imported Bible to Trash: \(error.localizedDescription)", presenter: .settings) }
    }
}
