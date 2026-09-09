import Foundation
import Combine

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    struct Entry: Codable, Hashable, Identifiable {
        let title: String
        let selectedAt: Date

        var id: String {
            "\(title)-\(selectedAt.timeIntervalSince1970)"
        }
    }

    struct WeekSection: Hashable, Identifiable {
        let weekStart: Date
        let title: String
        let items: [Entry]

        var id: Date {
            weekStart
        }
    }

    @Published private(set) var entries: [Entry] = []

    @Published private(set) var groupedSections: [WeekSection] = []

    @Published private(set) var issue: String?
    private var canPersist = true
    @Published private(set) var version: Int = 0

    var items: [String] {
        entries.map(\.title)
    }

    private static let maxWeekCount = 5
    private static let legacyUserDefaultsKey = "history"
    private let historyFileURL: URL

    init(fileURL: URL? = nil) {
        historyFileURL = fileURL ?? Self.makeHistoryFileURL()
        load()
        if fileURL == nil { migrateLegacyAppStorageIfNeeded() }
    }

    func append(_ rawItem: String) {
        let trimmed = rawItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        setEntries(
            Self.normalized(
            from: entries + [Entry(title: trimmed, selectedAt: Date())]
            )
        )
        persist()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        setEntries([])
        persist()
    }

    private func load() {
        do {
            let data = try Data(contentsOf: historyFileURL)
            if let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
                if decoded.contains(where: { SearchQuery(ask: $0.title).verseQuery() == nil }) {
                    recoverUnreadableFile(historyFileURL, error: CocoaError(.fileReadCorruptFile))
                }
                setEntries(Self.normalized(from: decoded), incrementVersion: false)
                return
            }

            if let legacyDecoded = try? JSONDecoder().decode([String].self, from: data) {
                if legacyDecoded.contains(where: { SearchQuery(ask: $0).verseQuery() == nil }) {
                    recoverUnreadableFile(historyFileURL, error: CocoaError(.fileReadCorruptFile))
                }
                setEntries(
                    Self.normalized(from: Self.legacyEntries(from: legacyDecoded)),
                    incrementVersion: false
                )
                persist() // Rewrite history file using the newer timestamped schema.
                return
            }

            throw CocoaError(.fileReadCorruptFile)
        } catch {
            recoverUnreadableFile(historyFileURL, error: error)
            setEntries([], incrementVersion: false)
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard canPersist else { return false }
        do {
            try FileManager.default.createDirectory(
                at: historyFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: historyFileURL, options: [.atomic])
            return true
        } catch {
            issue = "Could not save history: \(error.localizedDescription)"
            logger.error("Failed to persist history store: \(error.localizedDescription)")
            return false
        }
    }

    private func migrateLegacyAppStorageIfNeeded() {
        guard entries.isEmpty, !FileManager.default.fileExists(atPath: historyFileURL.path) else { return }
        guard let legacyRawValue = UserDefaults.standard.string(forKey: Self.legacyUserDefaultsKey),
              !legacyRawValue.isEmpty,
              let legacyData = legacyRawValue.data(using: .utf8),
              let legacyItems = try? JSONDecoder().decode([String].self, from: legacyData)
        else {
            return
        }

        setEntries(Self.normalized(from: Self.legacyEntries(from: legacyItems)))
        if persist() { UserDefaults.standard.removeObject(forKey: Self.legacyUserDefaultsKey) }
    }

    private func setEntries(_ newEntries: [Entry], incrementVersion: Bool = true) {
        entries = newEntries
        groupedSections = Self.makeGroupedSections(from: newEntries)
        if incrementVersion {
            version &+= 1
        }
    }

    private static func normalized(from values: [Entry], now: Date = Date()) -> [Entry] {
        var latestByTitle: [String: Entry] = [:]
        for value in values {
            guard let query = SearchQuery(ask: value.title).verseQuery() else { continue }
            let trimmed = query.title

            let cleaned = Entry(title: trimmed, selectedAt: value.selectedAt)
            if let existing = latestByTitle[trimmed] {
                if cleaned.selectedAt > existing.selectedAt {
                    latestByTitle[trimmed] = cleaned
                }
            } else {
                latestByTitle[trimmed] = cleaned
            }
        }

        let filtered = pruneToRecentWeeks(Array(latestByTitle.values), now: now)
        return filtered.sorted { $0.selectedAt < $1.selectedAt }
    }

    private static func makeGroupedSections(from values: [Entry], now: Date = Date()) -> [WeekSection] {
        let currentWeekStart = startOfWeek(for: now)
        let sorted = values.sorted { $0.selectedAt > $1.selectedAt }

        var grouped: [(Date, [Entry])] = []
        for value in sorted {
            let weekStart = startOfWeek(for: value.selectedAt)
            if let lastIndex = grouped.indices.last, grouped[lastIndex].0 == weekStart {
                grouped[lastIndex].1.append(value)
            } else {
                grouped.append((weekStart, [value]))
            }
        }

        return grouped.map { weekStart, weekEntries in
            WeekSection(
                weekStart: weekStart,
                title: weekLabel(for: weekStart, currentWeekStart: currentWeekStart),
                items: weekEntries
            )
        }
    }

    private static func weekLabel(for weekStart: Date, currentWeekStart: Date) -> String {
        let calendar = historyCalendar
        let diff = calendar.dateComponents([.weekOfYear], from: weekStart, to: currentWeekStart).weekOfYear ?? 0
        if diff <= 0 {
            return "This Week"
        }
        if diff == 1 {
            return "Last Week"
        }
        return "\(diff) Weeks Ago"
    }

    private static func pruneToRecentWeeks(_ values: [Entry], now: Date) -> [Entry] {
        let calendar = historyCalendar
        let currentWeekStart = startOfWeek(for: now)
        guard let oldestWeekStart = calendar.date(byAdding: .weekOfYear, value: -(maxWeekCount - 1), to: currentWeekStart) else {
            return values
        }

        return values.filter { entry in
            startOfWeek(for: entry.selectedAt) >= oldestWeekStart
        }
    }

    private static func startOfWeek(for date: Date) -> Date {
        let calendar = historyCalendar
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let daysSinceWeekStart = (weekday - calendar.firstWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: -daysSinceWeekStart, to: dayStart) ?? dayStart
    }

    private static var historyCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1 // Sunday
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }

    private static func legacyEntries(from values: [String], now: Date = Date()) -> [Entry] {
        values.enumerated().map { index, value in
            Entry(title: value, selectedAt: now.addingTimeInterval(TimeInterval(index)))
        }
    }

    private func recoverUnreadableFile(_ url: URL, error: Error) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if (error as NSError).code != NSFileReadNoSuchFileError { issue = error.localizedDescription }
            return
        }
        let backup = url.deletingPathExtension().appendingPathExtension("recovery-\(UUID().uuidString).json")
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            issue = "Could not read \(url.lastPathComponent). The original was preserved as \(backup.lastPathComponent)."
        } catch {
            canPersist = false
            issue = "Could not read or back up \(url.lastPathComponent). Saving is disabled to preserve the original."
        }
    }

    private static func makeHistoryFileURL() -> URL {
        let baseURL: URL
        do {
            baseURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }

        return baseURL
            .appendingPathComponent("ViewTheWord", isDirectory: true)
            .appendingPathComponent("history.json")
    }
}

@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()

    struct Entry: Codable, Hashable, Identifiable {
        let book: String
        let chapter: Int
        let verse: Int
        let createdAt: Date

        var id: String {
            "\(book)|\(chapter)|\(verse)"
        }

        var title: String {
            "\(book) \(chapter): \(verse)"
        }

        var reference: VerseReference? {
            VerseReference(book: book, chapter: chapter, verse: verse)
        }

        init(reference: VerseReference, createdAt: Date = Date()) {
            self.book = reference.book
            self.chapter = reference.chapter
            self.verse = reference.verse
            self.createdAt = createdAt
        }
    }

    @Published private(set) var entries: [Entry] = []

    @Published private(set) var issue: String?
    private var canPersist = true
    @Published private(set) var version: Int = 0

    private static let maxCount = 200
    private let bookmarkFileURL: URL
    private var entryIDs: Set<String> = []

    init(fileURL: URL? = nil) {
        bookmarkFileURL = fileURL ?? Self.makeBookmarkFileURL()
        load()
    }

    func add(_ reference: VerseReference, undoManager: UndoManager? = nil) {
        var nextEntries = entries
        nextEntries.removeAll { $0.id == Entry(reference: reference).id }
        nextEntries.append(Entry(reference: reference))
        replaceEntries(nextEntries, undoManager: undoManager, actionName: "Add Bookmark")
    }

    func remove(_ reference: VerseReference, undoManager: UndoManager? = nil) {
        let id = Entry(reference: reference).id
        let nextEntries = entries.filter { $0.id != id }
        replaceEntries(nextEntries, undoManager: undoManager, actionName: "Remove Bookmark")
    }

    func contains(_ reference: VerseReference) -> Bool {
        let id = Entry(reference: reference).id
        return entryIDs.contains(id)
    }

    func clear(undoManager: UndoManager? = nil) {
        replaceEntries([], undoManager: undoManager, actionName: "Clear Bookmarks")
    }

    private func replaceEntries(_ values: [Entry], undoManager: UndoManager?, actionName: String) {
        let next = Self.normalized(from: values)
        guard next != entries else { return }
        let removed = entries.filter { !next.contains($0) }
        let added = next.filter { !entries.contains($0) }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            // Reverse only this edit. A later edit without an undo manager must
            // not be erased by restoring an old snapshot of the entire store.
            var restored = store.entries.filter { !added.contains($0) }
            for entry in removed where !restored.contains(where: { $0.id == entry.id }) {
                restored.append(entry)
            }
            store.replaceEntries(restored, undoManager: undoManager, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        setEntries(next)
        persist()
    }

    private func load() {
        do {
            let data = try Data(contentsOf: bookmarkFileURL)
            let decoded = try JSONDecoder().decode([Entry].self, from: data)
            if decoded.contains(where: { $0.reference == nil }) {
                recoverUnreadableFile(bookmarkFileURL, error: CocoaError(.fileReadCorruptFile))
            }
            setEntries(Self.normalized(from: decoded), incrementVersion: false)
        } catch {
            recoverUnreadableFile(bookmarkFileURL, error: error)
            setEntries([], incrementVersion: false)
        }
    }

    private func persist() {
        guard canPersist else { return }
        do {
            try FileManager.default.createDirectory(
                at: bookmarkFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: bookmarkFileURL, options: [.atomic])
        } catch {
            issue = "Could not save bookmarks: \(error.localizedDescription)"
            logger.error("Failed to persist bookmark store: \(error.localizedDescription)")
        }
    }

    private static func normalized(from values: [Entry]) -> [Entry] {
        var latestByID: [String: Entry] = [:]
        for value in values {
            guard let reference = value.reference else { continue }
            let normalized = Entry(reference: reference, createdAt: value.createdAt)
            if let existing = latestByID[normalized.id] {
                if normalized.createdAt > existing.createdAt {
                    latestByID[normalized.id] = normalized
                }
            } else {
                latestByID[normalized.id] = normalized
            }
        }

        var normalized = latestByID.values.sorted { $0.createdAt < $1.createdAt }
        if normalized.count > maxCount {
            normalized.removeFirst(normalized.count - maxCount)
        }
        return normalized
    }

    private func setEntries(_ newEntries: [Entry], incrementVersion: Bool = true) {
        entries = newEntries
        entryIDs = Set(newEntries.map(\.id))
        if incrementVersion {
            version &+= 1
        }
    }

    private func recoverUnreadableFile(_ url: URL, error: Error) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if (error as NSError).code != NSFileReadNoSuchFileError { issue = error.localizedDescription }
            return
        }
        let backup = url.deletingPathExtension().appendingPathExtension("recovery-\(UUID().uuidString).json")
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            issue = "Could not read \(url.lastPathComponent). The original was preserved as \(backup.lastPathComponent)."
        } catch {
            canPersist = false
            issue = "Could not read or back up \(url.lastPathComponent). Saving is disabled to preserve the original."
        }
    }

    private static func makeBookmarkFileURL() -> URL {
        let baseURL: URL
        do {
            baseURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
        }

        return baseURL
            .appendingPathComponent("ViewTheWord", isDirectory: true)
            .appendingPathComponent("bookmarks.json")
    }
}
