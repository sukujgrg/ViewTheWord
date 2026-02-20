import Foundation
import SwiftUI
import OrderedCollections
import OSLog

let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ViewTheWord",
    category: "app"
)

enum AppWindowTitle {
    static let projector = "Projector"
}

enum AppDefaultsKey {
    static let apiUrlToPost = "apiUrlToPost"
    static let transparentBackground = "transparentBackground"
    static let preferDarkMode = "preferDarkMode"
    static let projectorTextAlignment = "projectorTextAlignment"
    static let projectorReadingDirection = "projectorReadingDirection"
    static let primaryBibleName = "PrimaryBibleName"
    static let secondaryBibleName = "SecondaryBibleName"
    static let showOnlyPrimary = "showOnlyPrimary"
    static let chapterHistorySplitAutosaveName = "chapterHistorySplit"
    static let bookmarkHistorySplitAutosaveName = "bookmarkHistorySplit"
}

enum ProjectorTextAlignmentMode: String, CaseIterable {
    case left
    case center
    case right
}

enum ProjectorReadingDirectionMode: String, CaseIterable {
    case auto
    case leftToRight
    case rightToLeft
}

enum BibleFileRule {
    static let fileExtension = "bible"
    static let fileNamePattern = #"^[A-Z]{3}_[A-Z]{3,6}\.bible$"#
    static let requiredBibleColumns: Set<String> = [
        "bnumber",
        "cnumber",
        "vnumber",
        "verse"
    ]

    static func isValidFileName(_ fileName: String) -> Bool {
        fileName.range(of: fileNamePattern, options: .regularExpression) != nil
    }
}

extension Notification.Name {
    static let focusSearchField = Notification.Name("FocusSearchField")
    static let toggleKeyboardShortcuts = Notification.Name("ToggleKeyboardShortcuts")
}

enum VerseBoundary {
    static func chapterRange(for book: String) -> ClosedRange<Int>? {
        guard let metadata = bibleBooks[book], metadata.count >= 2 else {
            return nil
        }
        let maxChapter = metadata[1]
        guard maxChapter > 0 else {
            return nil
        }
        return 1...maxChapter
    }

    static func isValidBook(_ book: String) -> Bool {
        chapterRange(for: book) != nil
    }

    static func isValidChapter(_ chapter: Int, in book: String) -> Bool {
        guard let range = chapterRange(for: book) else {
            return false
        }
        return range.contains(chapter)
    }

    static func isValidVerse(_ verse: Int) -> Bool {
        verse > 0
    }
}

struct VerseReference: Equatable, Sendable {
    let book: String
    let chapter: Int
    let verse: Int

    init?(book: String, chapter: Int, verse: Int) {
        guard VerseBoundary.isValidBook(book),
              VerseBoundary.isValidChapter(chapter, in: book),
              VerseBoundary.isValidVerse(verse) else {
            return nil
        }
        self.book = book
        self.chapter = chapter
        self.verse = verse
    }

    init?(_ query: VerseQuery) {
        self.init(book: query.bookName, chapter: query.chapterNumber, verse: query.verseNumber)
    }

    var verseQuery: VerseQuery {
        VerseQuery(bookName: book, chapterNumber: chapter, verseNumber: verse)
    }
}

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

    var items: [String] {
        entries.map(\.title)
    }

    var groupedSections: [WeekSection] {
        Self.makeGroupedSections(from: entries)
    }

    private static let maxWeekCount = 5
    private static let legacyUserDefaultsKey = "history"
    private let historyFileURL: URL

    private init() {
        historyFileURL = Self.makeHistoryFileURL()
        load()
        migrateLegacyAppStorageIfNeeded()
    }

    func append(_ rawItem: String) {
        let trimmed = rawItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries = Self.normalized(
            from: entries + [Entry(title: trimmed, selectedAt: Date())]
        )
        persist()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
    }

    private func load() {
        do {
            let data = try Data(contentsOf: historyFileURL)
            if let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
                entries = Self.normalized(from: decoded)
                return
            }

            if let legacyDecoded = try? JSONDecoder().decode([String].self, from: data) {
                entries = Self.normalized(from: Self.legacyEntries(from: legacyDecoded))
                persist() // Rewrite history file using the newer timestamped schema.
                return
            }

            entries = []
        } catch {
            entries = []
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: historyFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: historyFileURL, options: [.atomic])
        } catch {
            logger.error("Failed to persist history store: \(error.localizedDescription)")
        }
    }

    private func migrateLegacyAppStorageIfNeeded() {
        guard entries.isEmpty else { return }
        guard let legacyRawValue = UserDefaults.standard.string(forKey: Self.legacyUserDefaultsKey),
              !legacyRawValue.isEmpty,
              let legacyData = legacyRawValue.data(using: .utf8),
              let legacyItems = try? JSONDecoder().decode([String].self, from: legacyData)
        else {
            return
        }

        entries = Self.normalized(from: Self.legacyEntries(from: legacyItems))
        persist()
        UserDefaults.standard.removeObject(forKey: Self.legacyUserDefaultsKey)
    }

    private static func normalized(from values: [Entry], now: Date = Date()) -> [Entry] {
        var latestByTitle: [String: Entry] = [:]
        for value in values {
            let trimmed = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

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

    private static let maxCount = 200
    private let bookmarkFileURL: URL

    private init() {
        bookmarkFileURL = Self.makeBookmarkFileURL()
        load()
    }

    func add(_ reference: VerseReference) {
        entries.removeAll { $0.id == Entry(reference: reference).id }
        entries.append(Entry(reference: reference))
        entries = Self.normalized(from: entries)
        persist()
    }

    func remove(_ reference: VerseReference) {
        let id = Entry(reference: reference).id
        let originalCount = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != originalCount {
            persist()
        }
    }

    func contains(_ reference: VerseReference) -> Bool {
        let id = Entry(reference: reference).id
        return entries.contains { $0.id == id }
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        persist()
    }

    private func load() {
        do {
            let data = try Data(contentsOf: bookmarkFileURL)
            let decoded = try JSONDecoder().decode([Entry].self, from: data)
            entries = Self.normalized(from: decoded)
        } catch {
            entries = []
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: bookmarkFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(entries)
            try data.write(to: bookmarkFileURL, options: [.atomic])
        } catch {
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

let bundledPrimaryBibleUrl: URL? = Bundle.main.url(forResource: "MAL_BSI", withExtension: "bible")
let bundledSecondaryBibleUrl: URL? = Bundle.main.url(forResource: "ENG_UKJV", withExtension: "bible")

// bookName: [bookNumber, numberOfChapter]

let bibleBooks: OrderedDictionary<String, [Int]> = [
    "Genesis": [1, 50],
    "Exodus": [2, 40],
    "Leviticus": [3, 27],
    "Numbers": [4, 36],
    "Deuteronomy": [5, 34],
    "Joshua": [6, 24],
    "Judges": [7, 21],
    "Ruth": [8, 4],
    "1 Samuel": [9, 31],
    "2 Samuel": [10, 24],
    "1 Kings": [11, 22],
    "2 Kings": [12, 25],
    "1 Chronicles": [13, 29],
    "2 Chronicles": [14, 36],
    "Ezra": [15, 10],
    "Nehemiah": [16, 13],
    "Esther": [17, 10],
    "Job": [18, 42],
    "Psalm": [19, 150],
    "Proverbs": [20, 31],
    "Ecclesiastes": [21, 12],
    "Song of Solomon": [22, 8],
    "Isaiah": [23, 66],
    "Jeremiah": [24, 52],
    "Lamentations": [25, 5],
    "Ezekiel": [26, 48],
    "Daniel": [27, 12],
    "Hosea": [28, 14],
    "Joel": [29, 3],
    "Amos": [30, 9],
    "Obadiah": [31, 1],
    "Jonah": [32, 4],
    "Micah": [33, 7],
    "Nahum": [34, 3],
    "Habakkuk": [35, 3],
    "Zephaniah": [36, 3],
    "Haggai": [37, 2],
    "Zechariah": [38, 14],
    "Malachi": [39, 4],
    "Matthew": [40, 28],
    "Mark": [41, 16],
    "Luke": [42, 24],
    "John": [43, 21],
    "Acts": [44, 28],
    "Romans": [45, 16],
    "1 Corinthians": [46, 16],
    "2 Corinthians": [47, 13],
    "Galatians": [48, 6],
    "Ephesians": [49, 6],
    "Philippians": [50, 4],
    "Colossians": [51, 4],
    "1 Thessalonians": [52, 5],
    "2 Thessalonians": [53, 3],
    "1 Timothy": [54, 6],
    "2 Timothy": [55, 4],
    "Titus": [56, 3],
    "Philemon": [57, 1],
    "Hebrews": [58, 13],
    "James": [59, 5],
    "1 Peter": [60, 5],
    "2 Peter": [61, 3],
    "1 John": [62, 5],
    "2 John": [63, 1],
    "3 John": [64, 1],
    "Jude": [65, 1],
    "Revelation": [66, 22]
]
