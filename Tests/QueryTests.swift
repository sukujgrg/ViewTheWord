import XCTest
@testable import ViewTheWordCore

final class QueryTests: XCTestCase {
    func testShortBookPrefixesResolveInBibleOrder() throws {
        let cases: [(String, String, Int, Int)] = [
            ("p 1 1", "Psalm", 1, 1),
            ("p1 1", "Psalm", 1, 1),
            ("P 1:1", "Psalm", 1, 1),
            ("p140", "Psalm", 140, 1),
            ("p150 6", "Psalm", 150, 6),
            ("1p1 1", "1 Peter", 1, 1),
            ("1p", "1 Peter", 1, 1),
            ("1p5", "1 Peter", 5, 1),
            ("2p3 1", "2 Peter", 3, 1),
            ("1c1 1", "1 Chronicles", 1, 1),
            ("j1 1", "Joshua", 1, 1),
            ("phi1 1", "Philippians", 1, 1),
            ("phlm1 1", "Philemon", 1, 1),
            ("John1 1", "John", 1, 1)
        ]
        for (query, book, chapter, verse) in cases {
            XCTAssertEqual(try SearchQuery(ask: query).validatedVerseQuery(),
                           VerseQuery(bookName: book, chapterNumber: chapter, verseNumber: verse), query)
        }
    }

    func testShortBookPrefixesRespectChapterLimits() {
        for query in ["1p140", "1p6 1", "p151 1", "2p4 1", "1c30 1", "j25 1"] {
            XCTAssertThrowsError(try SearchQuery(ask: query).validatedVerseQuery(), query) { error in
                XCTAssertEqual(error as? QueryError, .invalidReference, query)
            }
        }
        XCTAssertThrowsError(try SearchQuery(ask: "zz1 1").validatedVerseQuery()) { error in
            XCTAssertEqual(error as? QueryError, .unknownBook)
        }
    }

    func testReferenceShorthandAndSeparators() throws {
        let cases: [(String, String, Int, Int)] = [
            ("psa 5 5", "Psalm", 5, 5),
            ("psa 5 1", "Psalm", 5, 1),
            ("psa 5", "Psalm", 5, 1),
            ("psa 55", "Psalm", 55, 1),
            ("psa", "Psalm", 1, 1),
            ("  PSA   5\t5  ", "Psalm", 5, 5),
            ("psa5 5", "Psalm", 5, 5),
            ("psa5:5", "Psalm", 5, 5),
            ("Psalm 5: 5", "Psalm", 5, 5),
            ("psa 5.5", "Psalm", 5, 5),
            ("1 cor 13 4", "1 Corinthians", 13, 4),
            ("1cor13 4", "1 Corinthians", 13, 4),
            ("Song of Solomon 2 1", "Song of Solomon", 2, 1)
        ]
        for (query, book, chapter, verse) in cases {
            guard case .verse(let reference) = try SearchQuery(ask: query).searchType(mode: .verseReference) else {
                XCTFail("Expected a verse reference for \(query)")
                continue
            }
            XCTAssertEqual(reference, VerseQuery(bookName: book, chapterNumber: chapter, verseNumber: verse), query)
        }
    }

    func testReferenceOverflowAndUnsupportedSyntax() throws {
        for query in [
            "John 3:2147483648", "John 3:999999999999999999999999999", "John 3:-1",
            "John 3:16-18", "John 0:1", "John 22:1", "John:16", "John 3:16 junk",
            "psa 5 2147483648", "psa 5 999999999999999999999999999", "psa 5 0", "psa 5 -1",
            "psa 5 5-7", "psa 5 5 7", "psa 5 5 junk", "psa 151 5"
        ] {
            XCTAssertThrowsError(try SearchQuery(ask: query).validatedVerseQuery(), query)
        }
        XCTAssertEqual(try SearchQuery(ask: "3 John 1:15").validatedVerseQuery().verseNumber, 15)
        XCTAssertEqual(try SearchQuery(ask: "Song of Solomon 2:1").validatedVerseQuery().bookName, "Song of Solomon")
    }
    func testOperatorPrecedenceAndImplicitAnd() throws {
        XCTAssertEqual(try SearchParser(query: "god OR love AND mercy").parse(), .or([.term("god"), .and([.term("love"), .term("mercy")])]))
        XCTAssertEqual(try SearchParser(query: "love NOT hate").parse(), .and([.term("love"), .not(.term("hate"))]))
        XCTAssertEqual(try SearchParser(query: "jesus\nmary").parse(), .and([.term("jesus"), .term("mary")]))
        for query in ["god AND", "(god", "god)", "()", "god OR OR love", "NOT", "\"god"] {
            XCTAssertThrowsError(try SearchParser(query: query).parse(), query)
        }
    }
    func testUnicodeWordBoundaries() throws {
        let matcher = try WordMatcher(term: "jesus")
        for text in ["JESUS:", "Jesus?", "(Jesus)", "Jesus—said"] { XCTAssertTrue(matcher.matches(text), text) }
        for text in ["jesuses", "my_jesus", "jesus\u{0301}"] { XCTAssertFalse(matcher.matches(text), text) }
        XCTAssertTrue(try WordMatcher(term: "ദൈവം").matches("ദൈവം: സ്നേഹം"))
        XCTAssertFalse(try WordMatcher(term: "ദൈവം").matches("ദൈവംക"))
    }
}
