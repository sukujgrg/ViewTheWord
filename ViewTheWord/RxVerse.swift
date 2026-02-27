import Foundation

enum SearchMode: String, CaseIterable {
    case verseReference
    case wordSearch
    case phraseSearch
}

enum SearchType {
    case verse(VerseQuery)
    case phrase(String, filter: SearchFilter)  // Phrase mode - exact phrase search
    case multiTerm(String, filter: SearchFilter)  // Words mode - search with AND/OR/NOT
}

enum SearchFilter: Sendable {
    case all
    case oldTestament
    case newTestament
    case book(String)

    func bookNumbers() -> [Int]? {
        switch self {
        case .all:
            return nil
        case .oldTestament:
            return Array(1...39) // First 39 books
        case .newTestament:
            return Array(40...66) // Books 40-66
        case .book(let bookName):
            return bibleBooks[bookName]?.first.map { [$0] }
        }
    }
}

// Search expression tree for parsing complex queries
indirect enum SearchExpression {
    case term(String)
    case and([SearchExpression])
    case or([SearchExpression])
    case not(SearchExpression)

    func toSQL() -> (whereClause: String, terms: [String]) {
        switch self {
        case .term(let word):
            // Match whole words only by checking for word boundaries
            // Checks for: word at start, word at end, word in middle, or word with punctuation
            let clauses = [
                "verse LIKE ?",  // word at start followed by space or punctuation
                "verse LIKE ?",  // word at end preceded by space or punctuation
                "verse LIKE ?",  // word in middle surrounded by spaces
                "verse LIKE ?",  // word followed by punctuation
                "verse LIKE ?",  // word preceded by punctuation
                "verse LIKE ?"   // word surrounded by punctuation
            ]
            let clause = "(" + clauses.joined(separator: " OR ") + ")"

            let terms = [
                "\(word) %",     // at start
                "% \(word)",     // at end
                "% \(word) %",   // in middle
                "% \(word),%",   // before comma
                "% \(word).%",   // before period
                "% \(word);%"    // before semicolon
            ]

            return (clause, terms)

        case .and(let expressions):
            let sqlParts = expressions.map { $0.toSQL() }
            let clauses = sqlParts.map { "(\($0.whereClause))" }.joined(separator: " AND ")
            let terms = sqlParts.flatMap { $0.terms }
            return (clauses, terms)

        case .or(let expressions):
            let sqlParts = expressions.map { $0.toSQL() }
            let clauses = sqlParts.map { "(\($0.whereClause))" }.joined(separator: " OR ")
            let terms = sqlParts.flatMap { $0.terms }
            return (clauses, terms)

        case .not(let expression):
            let sql = expression.toSQL()
            return ("NOT (\(sql.whereClause))", sql.terms)
        }
    }
}

class SearchParser {
    private let query: String
    private var tokens: [String] = []
    private var currentIndex = 0

    init(query: String) {
        self.query = query
        self.tokenize()
    }

    private func tokenize() {
        // Split by spaces but respect parentheses
        var currentToken = ""

        for char in query {
            if char == "(" || char == ")" {
                if !currentToken.isEmpty {
                    tokens.append(currentToken.trimmingCharacters(in: .whitespaces))
                    currentToken = ""
                }
                tokens.append(String(char))
            } else if char == " " {
                if !currentToken.isEmpty {
                    tokens.append(currentToken.trimmingCharacters(in: .whitespaces))
                    currentToken = ""
                }
            } else {
                currentToken.append(char)
            }
        }

        if !currentToken.isEmpty {
            tokens.append(currentToken.trimmingCharacters(in: .whitespaces))
        }
    }

    func parse() -> SearchExpression? {
        guard !tokens.isEmpty else { return nil }
        currentIndex = 0
        return parseExpression()
    }

    private func parseExpression() -> SearchExpression? {
        var left = parseTerm()

        while currentIndex < tokens.count {
            let token = tokens[currentIndex].uppercased()

            if token == "AND" {
                currentIndex += 1
                guard let right = parseTerm() else { return left }
                if case .and(var expressions) = left {
                    expressions.append(right)
                    left = .and(expressions)
                } else if let leftExpr = left {
                    left = .and([leftExpr, right])
                } else {
                    left = right
                }
            } else if token == "OR" {
                currentIndex += 1
                guard let right = parseTerm() else { return left }
                if case .or(var expressions) = left {
                    expressions.append(right)
                    left = .or(expressions)
                } else if let leftExpr = left {
                    left = .or([leftExpr, right])
                } else {
                    left = right
                }
            } else {
                break
            }
        }

        return left
    }

    private func parseTerm() -> SearchExpression? {
        guard currentIndex < tokens.count else { return nil }

        let token = tokens[currentIndex]

        // Handle NOT operator
        if token.uppercased() == "NOT" {
            currentIndex += 1
            guard let expr = parseTerm() else { return nil }
            return .not(expr)
        }

        // Handle parentheses
        if token == "(" {
            currentIndex += 1
            let expr = parseExpression()
            if currentIndex < tokens.count && tokens[currentIndex] == ")" {
                currentIndex += 1
            }
            return expr
        }

        // Handle regular term
        if token != ")" && !["AND", "OR", "NOT"].contains(token.uppercased()) {
            currentIndex += 1
            return .term(token)
        }

        return nil
    }
}

class SearchQuery {
    let ask: String
    private static let verseAskRegexPattern =
        #"(?<series>[1-3])?[^a-zA-Z0-9]*"#
        + #"(?<book>[a-zA-Z]+)\D*"#
        + #"(?<chapter>\d+)?"#
        + #"((?:\D+)(?<verse>\d+))?"#
    private static let verseAskRegex = try? NSRegularExpression(pattern: verseAskRegexPattern, options: [])

    init(ask: String) {
        self.ask = ask
    }

    func searchType(mode: SearchMode) -> SearchType? {
        switch mode {
        case .verseReference:
            guard let verseQuery = verseQuery() else { return nil }
            return .verse(verseQuery)
        case .wordSearch:
            let normalized = normalizedSearchTextForMode()
            guard !normalized.isEmpty else { return nil }
            let (filter, query) = parseSearchFilter(searchText: normalized)
            guard !query.isEmpty else { return nil }
            return .multiTerm(query, filter: filter)
        case .phraseSearch:
            let normalized = normalizedSearchTextForMode()
            guard !normalized.isEmpty else { return nil }
            let (filter, query) = parseSearchFilter(searchText: normalized)
            guard !query.isEmpty else { return nil }
            return .phrase(query, filter: filter)
        }
    }

    private func normalizedSearchTextForMode() -> String {
        let trimmed = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("s:") || lowered.hasPrefix("v:") || lowered.hasPrefix("m:") {
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private func parseSearchFilter(searchText: String) -> (SearchFilter, String) {
        let lowercased = searchText.lowercased()

        // Check for testament filters
        if lowercased.hasPrefix("ot:") {
            let query = searchText.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return (.oldTestament, query)
        }

        if lowercased.hasPrefix("nt:") {
            let query = searchText.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return (.newTestament, query)
        }

        // Check for book filter (e.g., "john: light")
        if let colonIndex = searchText.firstIndex(of: ":") {
            let bookPart = String(searchText[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let queryPart = String(searchText[searchText.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            // Try to match book name
            if let bookName = matchAsk(bookName: bookPart) {
                return (.book(bookName), queryPart)
            }
        }

        return (.all, searchText)
    }

    func verseQuery() -> VerseQuery? {
        guard let formattedAsk = formatVerseAsk() else { return nil }
        guard let bookName = matchAsk(bookName: formattedAsk.bookName) else { return nil }
        return VerseQuery(
            bookName: bookName, chapterNumber: formattedAsk.chapterNumber, verseNumber: formattedAsk.verseNumber
        )
    }

    func matchAsk(bookName: String) -> String? {
        for book in bibleBookNames {
            if book.range(of: bookName, options: [.anchored, .caseInsensitive]) != nil {
                return book
            }
        }
        return nil
    }

    func formatVerseAsk() -> VerseQuery? {
        let captureGroups = ["series", "book", "chapter", "verse"]

        let strRange = NSRange(ask.startIndex ..< ask.endIndex, in: ask)

        guard let nameRegex = Self.verseAskRegex else {
            logger.error("Failed to compile verse query regex")
            return nil
        }

        let matches = nameRegex.matches(in: ask, options: [], range: strRange)

        var bookName: String?
        var bookSeries = 0
        var chapterNum = 1
        var verseNum = 1

        for match in matches {
            for name in captureGroups {
                let matchRange = match.range(withName: name)
                if let substringRange = Range(matchRange, in: ask) {
                    let part = ask[substringRange].trimmingCharacters(in: .whitespaces)
                    if name == "book" {
                        bookName = String(part)
                    } else if name == "series" {
                        bookSeries = Int(part) ?? bookSeries
                    } else if name == "chapter" {
                        chapterNum = Int(part) ?? chapterNum
                    } else if name == "verse" {
                        verseNum = Int(part) ?? verseNum
                    }
                }
            }
        }
        if let book = bookName {
            if bookSeries == 0 {
                return VerseQuery(bookName: book, chapterNumber: chapterNum, verseNumber: verseNum)
            }
            return VerseQuery(bookName: "\(bookSeries) \(book)", chapterNumber: chapterNum, verseNumber: verseNum)
        }
        return nil
    }
}
