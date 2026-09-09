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
    @Published var pendingReplacement: URL?
    @Published var notice: String?
    var presentationTarget: Presenter = .settings
    private let importService = BibleImportService()

    init() { refresh() }
    func refresh() {
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
        let defaults = BibleUrl()
        func resolve(_ value: String, fallback: URL) -> URL {
            let filename = URL(string: value)?.lastPathComponent ?? ""
            return urls.first { $0.lastPathComponent == filename } ?? fallback
        }
        return BibleSources(primary: resolve(primary, fallback: defaults.primaryBibleUrl),
                            secondary: primaryOnly ? nil : resolve(secondary, fallback: defaults.secondaryBibleUrl), revision: revision)
    }
}

extension BibleLibrary {
    enum Presenter { case main, settings }

    func importFile(_ url: URL, replaceExisting: Bool = false, presenter: Presenter) {
        guard !isImporting else { return }
        isImporting = true
        presentationTarget = presenter
        pendingReplacement = nil
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                isImporting = false
            }
            do {
                let imported = try await importService.importBible(selectedFile: url, bundledBibleNames: bundledNames, replaceExisting: replaceExisting)
                refresh()
                notice = "Imported \(BibleTranslation.name(for: imported)). It is now available in the translation pickers."
            } catch BibleImportError.bibleAlreadyExists {
                pendingReplacement = url
            } catch { notice = error.localizedDescription }
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
        presentationTarget = .settings
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            refresh()
        } catch { notice = "Could not move the imported Bible to Trash: \(error.localizedDescription)" }
    }
}
