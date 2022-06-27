import Foundation

class SearchQuery {
    let ask: String

    init(ask: String) {
        self.ask = ask
    }

    func verseQuery() -> VerseQuery? {
        if let formattedAsk = formatVerseAsk() {
            if let bookName = matchAsk(bookName: formattedAsk.bookName) {
                return VerseQuery(bookName: bookName, chapterNumber: formattedAsk.chapterNumber, verseNumber: formattedAsk.verseNumber)
            }
        }
        return nil
    }

    func matchAsk(bookName: String) -> String? {
        for book in bibleBooks.keys {
            if book.range(of: bookName, options: [.anchored, .caseInsensitive]) != nil {
                return book
            }
        }
        return nil
    }

    func formatVerseAsk() -> VerseQuery? {
        let regex =
            #"(?<series>[1-3])?[^a-zA-Z0-9]*"# +
            #"(?<book>[a-zA-Z]+)\D*"# +
            #"(?<chapter>\d+)?"# +
            #"((?:\D+)(?<verse>\d+))?"#
        let captureGroups = ["series", "book", "chapter", "verse"]

        let strRange = NSRange(ask.startIndex ..< ask.endIndex, in: ask)
        let nameRegex = try! NSRegularExpression(pattern: regex, options: [])

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
