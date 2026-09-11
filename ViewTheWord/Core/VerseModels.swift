import Foundation
import Combine

struct VerseQuery: Equatable, Sendable {
    let bookName: String
    let chapterNumber: Int
    let verseNumber: Int
    var title: String { "\(bookName) \(chapterNumber):\(verseNumber)" }
    var bookAndChapter: String { "\(bookName) \(chapterNumber)" }
}

struct VerseCoordinate: Hashable, Comparable, Sendable {
    let book: Int
    let chapter: Int
    let verse: Int
    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.book, lhs.chapter, lhs.verse) < (rhs.book, rhs.chapter, rhs.verse)
    }
}

struct VerseReference: Hashable, Codable, Sendable {
    let book: String
    let chapter: Int
    let verse: Int

    init?(book: String, chapter: Int, verse: Int) {
        guard VerseBoundary.isValidChapter(chapter, in: book), VerseBoundary.isValidVerse(verse) else { return nil }
        self.book = book
        self.chapter = chapter
        self.verse = verse
    }
    init?(_ query: VerseQuery) { self.init(book: query.bookName, chapter: query.chapterNumber, verse: query.verseNumber) }
    var verseQuery: VerseQuery { VerseQuery(bookName: book, chapterNumber: chapter, verseNumber: verse) }
    var coordinate: VerseCoordinate { VerseCoordinate(book: bibleBooks[book]![0], chapter: chapter, verse: verse) }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let reference = Self(book: try values.decode(String.self, forKey: .book),
                                   chapter: try values.decode(Int.self, forKey: .chapter),
                                   verse: try values.decode(Int.self, forKey: .verse)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid verse reference"))
        }
        self = reference
    }
}

struct AVerse: Identifiable, Equatable, Sendable {
    let reference: VerseReference
    let verse: String
    var id: VerseCoordinate { reference.coordinate }
    var bookNumber: Int { id.book }
    var bookName: String { reference.book }
    var chapterNumber: Int { reference.chapter }
    var verseNumber: Int { reference.verse }
}

struct BibleSources: Equatable, Sendable {
    let primary: URL
    let secondary: URL?
    let revision: Int
}

/// A value copied when opening a passage, then edited independently in that tab.
/// Keep the last secondary URL when None is selected, including in saved preferences.
struct PassageTranslations: Equatable, Sendable {
    var primary: URL?
    var secondary: URL?
    var primaryOnly: Bool
}

struct ProjectionSource: Equatable, Sendable {
    let tabID: UUID?
    let sources: BibleSources
}

struct VerseRowData: Identifiable, Sendable {
    let id = UUID()
    let primaryChapter: [AVerse]
    let secondaryChapter: [AVerse]
    static var empty: Self { Self(primaryChapter: [], secondaryChapter: []) }
}

struct TranslationPair: Identifiable, Equatable, Sendable {
    let reference: VerseReference
    let primary: AVerse?
    let secondary: AVerse?
    var id: VerseCoordinate { reference.coordinate }
}

struct LoadedChapter: Sendable {
    let sources: BibleSources
    let rows: [TranslationPair]
    let data: VerseRowData
    private let rowByReference: [VerseReference: TranslationPair]

    init(reference: VerseReference, sources: BibleSources, primary: [AVerse], secondary: [AVerse]) throws {
        let secondary = sources.secondary == nil ? [] : secondary
        guard (primary + secondary).allSatisfy({ $0.bookName == reference.book && $0.chapterNumber == reference.chapter }) else {
            throw BibleError.invalidData("Chapter contains a verse with different coordinates.")
        }
        self.sources = sources
        self.rows = try Self.merge(primary: primary, secondary: secondary)
        self.rowByReference = Dictionary(uniqueKeysWithValues: rows.map { ($0.reference, $0) })
        self.data = VerseRowData(primaryChapter: primary, secondaryChapter: secondary)
    }

    static func merge(primary: [AVerse], secondary: [AVerse]) throws -> [TranslationPair] {
        func index(_ verses: [AVerse]) throws -> [VerseCoordinate: AVerse] {
            var result: [VerseCoordinate: AVerse] = [:]
            for verse in verses {
                guard result.updateValue(verse, forKey: verse.id) == nil else {
                    throw BibleError.invalidData("Duplicate verse coordinates.")
                }
            }
            return result
        }
        let first = try index(primary), second = try index(secondary)
        return Set(first.keys).union(second.keys).sorted().map { key in
            TranslationPair(reference: (first[key] ?? second[key])!.reference, primary: first[key], secondary: second[key])
        }
    }

    func row(at reference: VerseReference) -> TranslationPair? { rowByReference[reference] }
    func resolvedReference(_ requested: VerseReference) -> VerseReference? {
        row(at: requested)?.reference ?? rows.last(where: { $0.reference.verse <= requested.verse })?.reference ?? rows.first?.reference
    }
}

enum ProjectionOwner: Equatable, Sendable {
    case textInputTarget(VerseReference), verseRowSelection(VerseReference), searchResult(VerseReference)
    var reference: VerseReference {
        switch self {
        case .textInputTarget(let ref), .verseRowSelection(let ref), .searchResult(let ref): return ref
        }
    }
}

struct ProjectorViewData: Equatable, Sendable {
    let title: String
    let primaryText: String
    let secondaryText: String?
    let primaryTranslationName: String
    let secondaryTranslationName: String?
    static let empty = Self(title: "", primaryText: "", secondaryText: nil, primaryTranslationName: "", secondaryTranslationName: nil)
}

struct PreparedProjection: Sendable {
    let data: ProjectorViewData
    let owner: ProjectionOwner
    let sources: BibleSources
    init?(pair: TranslationPair, sources: BibleSources, owner: ProjectionOwner) {
        guard pair.reference == owner.reference else { return nil }
        let secondary = sources.secondary == nil ? nil : pair.secondary
        guard let first = pair.primary ?? secondary else { return nil }
        data = ProjectorViewData(
            title: pair.reference.verseQuery.title, primaryText: first.verse,
            secondaryText: pair.primary == nil ? nil : secondary?.verse,
            primaryTranslationName: BibleTranslation.name(for: pair.primary == nil ? (sources.secondary ?? sources.primary) : sources.primary),
            secondaryTranslationName: pair.primary != nil && secondary != nil ? sources.secondary.map(BibleTranslation.name) : nil
        )
        self.owner = owner
        self.sources = sources
    }
}

@MainActor
final class ProjectorViewModel: ObservableObject {
    struct Projection { let data: ProjectorViewData; let owner: ProjectionOwner; var blanked: Bool }
    @Published private(set) var projection: Projection?
    private(set) var revision = 0
    var projectorViewData: ProjectorViewData { projection?.data ?? .empty }
    var projectionOwner: ProjectionOwner? { projection?.owner }
    var isBlanked: Bool { projection?.blanked ?? false }

    func project(_ data: ProjectorViewData, owner: ProjectionOwner, preserveBlanking: Bool = false) {
        revision += 1
        projection = Projection(data: data, owner: owner, blanked: preserveBlanking && isBlanked)
    }
    func clearProjection() { revision += 1; projection = nil }
    func toggleBlank() { projection?.blanked.toggle() }
}
