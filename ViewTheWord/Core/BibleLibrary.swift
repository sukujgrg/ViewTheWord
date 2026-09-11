import Foundation
import Combine

@MainActor
final class BibleUrl {
    private static var cachedAvailableBibleUrls: [URL]?

    var primaryBibleUrl: URL
    var secondaryBibleUrl: URL

    static func invalidateAvailableBibleUrlCache() {
        cachedAvailableBibleUrls = nil
    }

    init() {
        primaryBibleUrl = bundledPrimaryBibleUrl ?? URL(fileURLWithPath: "/dev/null")
        secondaryBibleUrl = bundledSecondaryBibleUrl ?? primaryBibleUrl

        let availableBibleUrls = getAvailableBibleUrls()

        let fallbackURL = availableBibleUrls.first ?? URL(fileURLWithPath: "/dev/null")
        if fallbackURL.path == "/dev/null" {
            logger.fault("No Bible files are available; using /dev/null as a non-crashing placeholder.")
        }

        if let primary = getBibleUrl(defaultsKey: AppDefaultsKey.primaryBibleName) {
            primaryBibleUrl = primary
        } else if let bundledPrimary = bundledPrimaryBibleUrl {
            primaryBibleUrl = bundledPrimary
        } else if let firstAvailable = availableBibleUrls.first {
            logger.warning("Bundled primary Bible missing; falling back to \(firstAvailable.lastPathComponent).")
            primaryBibleUrl = firstAvailable
        } else {
            primaryBibleUrl = fallbackURL
        }

        if let secondary = getBibleUrl(defaultsKey: AppDefaultsKey.secondaryBibleName) {
            secondaryBibleUrl = secondary
        } else if let bundledSecondary = bundledSecondaryBibleUrl {
            secondaryBibleUrl = bundledSecondary
        } else if let secondaryFallback = availableBibleUrls.first(where: { $0 != primaryBibleUrl }) {
            logger.warning("Bundled secondary Bible missing; falling back to \(secondaryFallback.lastPathComponent).")
            secondaryBibleUrl = secondaryFallback
        } else {
            secondaryBibleUrl = primaryBibleUrl
        }
    }

    func getBibleUrl(defaultsKey: String) -> URL? {
        let availableBibleUrls = getAvailableBibleUrls()

        let defaults = UserDefaults.standard

        if let bibleName = defaults.string(forKey: defaultsKey), !bibleName.isEmpty {
            let storedLastPath = URL(string: bibleName)?.lastPathComponent
                ?? URL(fileURLWithPath: bibleName).lastPathComponent

            for url in availableBibleUrls where url.lastPathComponent == storedLastPath {
                return url
            }
        }
        return nil
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
    private let importer: Importer

    /// A supplied catalog lets native fixtures use repository data without
    /// discovering translations in the operator's Documents directory.
    init(preloadedURLs: [URL]? = nil, importer: Importer? = nil) {
        let service = BibleImportService()
        self.importer = importer ?? { url, bundledNames, replaceExisting in
            try await service.importBible(selectedFile: url, bundledBibleNames: bundledNames, replaceExisting: replaceExisting)
        }
        usesSuppliedCatalog = preloadedURLs != nil
        if let preloadedURLs {
            urls = preloadedURLs.sorted { $0.lastPathComponent < $1.lastPathComponent }
            revision = 1
        } else { refresh() }
    }
    func refresh() {
        guard !usesSuppliedCatalog else { revision += 1; return }
        BibleUrl.invalidateAvailableBibleUrlCache()
        urls = BibleUrl().getAvailableBibleUrls().sorted { $0.lastPathComponent < $1.lastPathComponent }
        for key in [AppDefaultsKey.primaryBibleName, AppDefaultsKey.secondaryBibleName] {
            if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
                let defaults = BibleUrl()
                let fallback = key == AppDefaultsKey.primaryBibleName ? defaults.primaryBibleUrl : defaults.secondaryBibleUrl
                let resolved = urls.first { $0.lastPathComponent == URL(string: stored)?.lastPathComponent } ?? fallback
                if resolved.absoluteString != stored { UserDefaults.standard.set(resolved.absoluteString, forKey: key) }
            }
        }
        revision += 1
    }
    func sources(primary: String, secondary: String, primaryOnly: Bool) -> BibleSources {
        func resolve(_ value: String) -> URL? {
            let filename = URL(string: value)?.lastPathComponent ?? ""
            return urls.first { $0.lastPathComponent == filename }
        }
        // Fallbacks depend on the catalog, never another tab's saved preferences.
        // Supplied test catalogs also avoid discovering the user's Documents.
        let first = resolve(primary) ?? resolve(bundledPrimaryBibleUrl?.absoluteString ?? "")
            ?? urls.first ?? URL(fileURLWithPath: "/dev/null")
        let second = resolve(secondary) ?? resolve(bundledSecondaryBibleUrl?.absoluteString ?? "")
            ?? urls.first(where: { $0 != first }) ?? first
        return BibleSources(primary: first, secondary: primaryOnly ? nil : second, revision: revision)
    }

    func defaultTranslations(_ defaults: UserDefaults) -> PassageTranslations {
        let sources = sources(primary: defaults.string(forKey: AppDefaultsKey.primaryBibleName) ?? "",
                              secondary: defaults.string(forKey: AppDefaultsKey.secondaryBibleName) ?? "", primaryOnly: false)
        return PassageTranslations(primary: sources.primary, secondary: sources.secondary ?? sources.primary,
                                   primaryOnly: defaults.bool(forKey: AppDefaultsKey.showOnlyPrimary))
    }

    func resolve(_ translations: PassageTranslations) -> PassageTranslations {
        let sources = sources(primary: translations.primary.absoluteString, secondary: translations.secondary.absoluteString,
                              primaryOnly: false)
        return PassageTranslations(primary: sources.primary, secondary: sources.secondary ?? sources.primary,
                                   primaryOnly: translations.primaryOnly)
    }

    func sources(for translations: PassageTranslations) -> BibleSources {
        sources(primary: translations.primary.absoluteString, secondary: translations.secondary.absoluteString,
                primaryOnly: translations.primaryOnly)
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
