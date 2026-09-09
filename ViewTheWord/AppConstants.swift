import Foundation
import OSLog

let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "ViewTheWord",
    category: "app"
)

enum AppWindowTitle {
    static let projector = "Projector"
}

enum AppDefaultsKey {
    static let fontSizeVerse = "fontSizeVerse"
    static let fontSizeVerseRef = "fontSizeVerseRef"
    static let projectorPadding = "vStackPadding"
    static let transparentBackground = "transparentBackground"
    static let preferDarkMode = "preferDarkMode"
    static let verseRowFontSize = "verseRowFontSize"
    static let projectorTextAlignment = "projectorTextAlignment"
    static let projectorReadingDirection = "projectorReadingDirection"
    static let projectorDualLayoutVertical = "projectorDualLayoutVertical"
    static let projectorShowTranslationInfo = "projectorShowTranslationInfo"
    static let primaryBibleName = "PrimaryBibleName"
    static let secondaryBibleName = "SecondaryBibleName"
    static let showOnlyPrimary = "showOnlyPrimary"
    static let chapterHistorySplitAutosaveName = "chapterHistorySplit"
    static let bookmarkHistorySplitAutosaveName = "bookmarkHistorySplit"
    static let projectorScreenDisplayID = "projectorScreenDisplayID"
    static let searchRecents = "searchRecents"
}

enum ProjectorTextAlignmentMode: String, CaseIterable, Sendable {
    case left
    case center
    case right
}

enum ProjectorReadingDirectionMode: String, CaseIterable, Sendable {
    case auto
    case leftToRight
    case rightToLeft
}

enum AppDefaults {
    static let verseFontSize = 100.0
    static let referenceFontSize = 36.0
    static let projectorPadding = 20.0
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
    static let closeProjectorRequested = Notification.Name("CloseProjectorRequested")
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
        verse > 0 && verse <= Int(Int32.max)
    }
}

let bundledPrimaryBibleUrl: URL? = Bundle.main.url(forResource: "MAL_BSI", withExtension: "bible")
let bundledSecondaryBibleUrl: URL? = Bundle.main.url(forResource: "ENG_UKJV", withExtension: "bible")

let bibleBookMetadata: [(name: String, number: Int, chapters: Int)] = [
    ("Genesis", 1, 50),
    ("Exodus", 2, 40),
    ("Leviticus", 3, 27),
    ("Numbers", 4, 36),
    ("Deuteronomy", 5, 34),
    ("Joshua", 6, 24),
    ("Judges", 7, 21),
    ("Ruth", 8, 4),
    ("1 Samuel", 9, 31),
    ("2 Samuel", 10, 24),
    ("1 Kings", 11, 22),
    ("2 Kings", 12, 25),
    ("1 Chronicles", 13, 29),
    ("2 Chronicles", 14, 36),
    ("Ezra", 15, 10),
    ("Nehemiah", 16, 13),
    ("Esther", 17, 10),
    ("Job", 18, 42),
    ("Psalm", 19, 150),
    ("Proverbs", 20, 31),
    ("Ecclesiastes", 21, 12),
    ("Song of Solomon", 22, 8),
    ("Isaiah", 23, 66),
    ("Jeremiah", 24, 52),
    ("Lamentations", 25, 5),
    ("Ezekiel", 26, 48),
    ("Daniel", 27, 12),
    ("Hosea", 28, 14),
    ("Joel", 29, 3),
    ("Amos", 30, 9),
    ("Obadiah", 31, 1),
    ("Jonah", 32, 4),
    ("Micah", 33, 7),
    ("Nahum", 34, 3),
    ("Habakkuk", 35, 3),
    ("Zephaniah", 36, 3),
    ("Haggai", 37, 2),
    ("Zechariah", 38, 14),
    ("Malachi", 39, 4),
    ("Matthew", 40, 28),
    ("Mark", 41, 16),
    ("Luke", 42, 24),
    ("John", 43, 21),
    ("Acts", 44, 28),
    ("Romans", 45, 16),
    ("1 Corinthians", 46, 16),
    ("2 Corinthians", 47, 13),
    ("Galatians", 48, 6),
    ("Ephesians", 49, 6),
    ("Philippians", 50, 4),
    ("Colossians", 51, 4),
    ("1 Thessalonians", 52, 5),
    ("2 Thessalonians", 53, 3),
    ("1 Timothy", 54, 6),
    ("2 Timothy", 55, 4),
    ("Titus", 56, 3),
    ("Philemon", 57, 1),
    ("Hebrews", 58, 13),
    ("James", 59, 5),
    ("1 Peter", 60, 5),
    ("2 Peter", 61, 3),
    ("1 John", 62, 5),
    ("2 John", 63, 1),
    ("3 John", 64, 1),
    ("Jude", 65, 1),
    ("Revelation", 66, 22)
]

let bibleBookNames: [String] = bibleBookMetadata.map(\.name)

// bookName: [bookNumber, numberOfChapter]
let bibleBooks: [String: [Int]] = Dictionary(
    uniqueKeysWithValues: bibleBookMetadata.map { entry in
        (entry.name, [entry.number, entry.chapters])
    }
)
