import Foundation

enum SearchMode: String, CaseIterable, Sendable {
    case verseReference, wordSearch, phraseSearch
}

enum SearchType: Sendable {
    case verse(VerseQuery)
    case text(TextSearchRequest)
}

enum SearchFilter: Equatable, Sendable {
    case all, oldTestament, newTestament, book(String)

    func bookNumbers() -> [Int]? {
        switch self {
        case .all: return nil
        case .oldTestament: return Array(1...39)
        case .newTestament: return Array(40...66)
        case .book(let name): return bibleBooks[name]?.first.map { [$0] }
        }
    }
}

enum QueryError: LocalizedError, Equatable {
    case invalidReference, unknownBook, invalidExpression(String), tooLong
    var errorDescription: String? {
        switch self {
        case .invalidReference: return "Check the reference and try again, for example John 3:16."
        case .unknownBook: return "That book name wasn't recognized. Try its full name."
        case .invalidExpression(let detail): return "Words search: \(detail)"
        case .tooLong: return "The search is too complex. Use at most 4,096 characters, 256 terms/operators, and 32 nested groups."
        }
    }
}

struct TextSearchRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case phrase(String), words(SearchExpression)
    }
    let text: String
    let filter: SearchFilter
    let kind: Kind
}

indirect enum SearchExpression: Equatable, Sendable {
    case term(String), and([SearchExpression]), or([SearchExpression]), not(SearchExpression)

    func toSQL() -> (whereClause: String, terms: [String]) {
        switch self {
        case .term(let word): return ("word_matches(verse, ?) = 1", [word])
        case .and(let children), .or(let children):
            let parts = children.map { $0.toSQL() }
            let separator: String
            if case .and = self { separator = " AND " } else { separator = " OR " }
            return (parts.map { "(\($0.whereClause))" }.joined(separator: separator), parts.flatMap(\.terms))
        case .not(let child):
            let part = child.toSQL()
            return ("NOT (\(part.whereClause))", part.terms)
        }
    }
}

/// NOT binds before AND (including adjacent words), which binds before OR.
struct SearchParser {
    private enum Token: Equatable { case word(String), and, or, not, open, close }
    let query: String
    private var tokens: [Token] = []
    private var index = 0

    init(query: String) { self.query = query }

    func parse() throws -> SearchExpression {
        guard query.count <= 4_096 else { throw QueryError.tooLong }
        var parser = self
        parser.tokens = try Self.tokenize(query)
        guard !parser.tokens.isEmpty else { throw QueryError.invalidExpression("enter at least one word.") }
        let result = try parser.parseOr(depth: 0)
        guard parser.index == parser.tokens.count else { throw QueryError.invalidExpression("unexpected closing parenthesis.") }
        return result
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        var result: [Token] = []
        var word = ""
        var quoted = false
        func flush(literal: Bool = false) {
            guard !word.isEmpty else { return }
            if literal { result.append(.word(word)) }
            else {
                switch word.uppercased() {
                case "AND": result.append(.and)
                case "OR": result.append(.or)
                case "NOT": result.append(.not)
                default: result.append(.word(word))
                }
            }
            word = ""
        }
        for character in text {
            if character == "\"" {
                if quoted {
                    guard !word.isEmpty else { throw QueryError.invalidExpression("empty quoted term.") }
                    flush(literal: true)
                } else { flush() }
                quoted.toggle()
            } else if quoted { word.append(character) }
            else if character.isWhitespace { flush() }
            else if character == "(" || character == ")" {
                flush()
                result.append(character == "(" ? .open : .close)
            } else { word.append(character) }
            guard result.count <= 256 else { throw QueryError.tooLong }
        }
        guard !quoted else { throw QueryError.invalidExpression("close the quotation mark.") }
        flush()
        guard result.count <= 256 else { throw QueryError.tooLong }
        return result
    }

    private mutating func consume(_ token: Token) -> Bool {
        guard index < tokens.count, tokens[index] == token else { return false }
        index += 1
        return true
    }

    private mutating func parseOr(depth: Int) throws -> SearchExpression {
        var children = [try parseAnd(depth: depth)]
        while consume(.or) { children.append(try parseAnd(depth: depth)) }
        return children.count == 1 ? children[0] : .or(children)
    }

    private mutating func parseAnd(depth: Int) throws -> SearchExpression {
        var children = [try parseUnary(depth: depth)]
        while index < tokens.count {
            if consume(.and) { children.append(try parseUnary(depth: depth)); continue }
            switch tokens[index] {
            case .word, .open, .not: children.append(try parseUnary(depth: depth))
            default: return children.count == 1 ? children[0] : .and(children)
            }
        }
        return children.count == 1 ? children[0] : .and(children)
    }

    private mutating func parseUnary(depth: Int) throws -> SearchExpression {
        guard depth < 32 else { throw QueryError.tooLong }
        if consume(.not) { return .not(try parseUnary(depth: depth + 1)) }
        if consume(.open) {
            let value = try parseOr(depth: depth + 1)
            guard consume(.close) else { throw QueryError.invalidExpression("close the parenthesis.") }
            return value
        }
        guard index < tokens.count, case .word(let word) = tokens[index] else {
            throw QueryError.invalidExpression("an operator or group is missing a word.")
        }
        index += 1
        return .term(word)
    }
}

struct SearchQuery {
    let ask: String
    private static let referenceRegex = try! NSRegularExpression(
        pattern: #"^\s*(?<series>[1-3])?\s*(?<book>[a-zA-Z]+(?:\s+[a-zA-Z]+)*?)\s*(?<chapter>[0-9]+)?(?:(?:\s*[:.]\s*|\s+)(?<verse>[0-9]+))?\s*$"#
    )

    func searchType(mode: SearchMode) throws -> SearchType {
        guard ask.count <= 4_096 else { throw QueryError.tooLong }
        if mode == .verseReference { return .verse(try validatedVerseQuery()) }
        var text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["s:", "v:", "m:"].contains(where: { text.lowercased().hasPrefix($0) }) {
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var filter: SearchFilter = .all
        if let colon = text.firstIndex(of: ":") {
            let prefix = String(text[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let selected: SearchFilter?
            if prefix.lowercased() == "ot" { selected = .oldTestament }
            else if prefix.lowercased() == "nt" { selected = .newTestament }
            else { selected = matchAsk(bookName: prefix).map(SearchFilter.book) }
            if let selected {
                filter = selected
                text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !text.isEmpty else { throw QueryError.invalidExpression("enter some text to search.") }
        let kind: TextSearchRequest.Kind = mode == .phraseSearch
            ? .phrase(text) : .words(try SearchParser(query: text).parse())
        return .text(TextSearchRequest(text: text, filter: filter, kind: kind))
    }

    func verseQuery() -> VerseQuery? { try? validatedVerseQuery() }

    func validatedVerseQuery() throws -> VerseQuery {
        guard ask.count <= 4_096 else { throw QueryError.tooLong }
        guard let match = Self.referenceRegex.firstMatch(in: ask, range: NSRange(ask.startIndex..., in: ask)) else {
            throw QueryError.invalidReference
        }
        func capture(_ name: String) -> String? {
            Range(match.range(withName: name), in: ask).map { String(ask[$0]) }
        }
        let rawBook = [capture("series"), capture("book")].compactMap { $0 }.joined(separator: " ")
        guard let book = matchAsk(bookName: rawBook) else { throw QueryError.unknownBook }
        func number(_ name: String) throws -> Int {
            guard let raw = capture(name) else { return 1 }
            guard let value = Int(raw), VerseBoundary.isValidVerse(value) else { throw QueryError.invalidReference }
            return value
        }
        guard capture("verse") == nil || capture("chapter") != nil else { throw QueryError.invalidReference }
        let chapter = try number("chapter")
        let verse = try number("verse")
        guard let reference = VerseReference(book: book, chapter: chapter, verse: verse) else {
            throw QueryError.invalidReference
        }
        return reference.verseQuery
    }

    func matchAsk(bookName: String) -> String? {
        let key = bookName.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !key.isEmpty else { return nil }
        let aliases = ["psalms": "Psalm", "ps": "Psalm", "jn": "John", "phil": "Philippians", "phlm": "Philemon", "song of songs": "Song of Solomon"]
        if let alias = aliases[key] { return alias }
        if let exact = bibleBookNames.first(where: { $0.lowercased() == key }) { return exact }
        // Preserve shorthand by choosing the first prefix match in Bible order.
        return bibleBookNames.first { $0.lowercased().hasPrefix(key) }
    }
}
