#!/usr/bin/env python3

import argparse
import re
import sqlite3
import sys
import xml.etree.ElementTree as ET

from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


FILE_NAME_PATTERN = re.compile(r"^[A-Z]{3}_[A-Z]{3,6}\.bible$")

CANONICAL_BOOKS: List[Tuple[str, int]] = [
    ("Genesis", 50),
    ("Exodus", 40),
    ("Leviticus", 27),
    ("Numbers", 36),
    ("Deuteronomy", 34),
    ("Joshua", 24),
    ("Judges", 21),
    ("Ruth", 4),
    ("1 Samuel", 31),
    ("2 Samuel", 24),
    ("1 Kings", 22),
    ("2 Kings", 25),
    ("1 Chronicles", 29),
    ("2 Chronicles", 36),
    ("Ezra", 10),
    ("Nehemiah", 13),
    ("Esther", 10),
    ("Job", 42),
    ("Psalm", 150),
    ("Proverbs", 31),
    ("Ecclesiastes", 12),
    ("Song of Solomon", 8),
    ("Isaiah", 66),
    ("Jeremiah", 52),
    ("Lamentations", 5),
    ("Ezekiel", 48),
    ("Daniel", 12),
    ("Hosea", 14),
    ("Joel", 3),
    ("Amos", 9),
    ("Obadiah", 1),
    ("Jonah", 4),
    ("Micah", 7),
    ("Nahum", 3),
    ("Habakkuk", 3),
    ("Zephaniah", 3),
    ("Haggai", 2),
    ("Zechariah", 14),
    ("Malachi", 4),
    ("Matthew", 28),
    ("Mark", 16),
    ("Luke", 24),
    ("John", 21),
    ("Acts", 28),
    ("Romans", 16),
    ("1 Corinthians", 16),
    ("2 Corinthians", 13),
    ("Galatians", 6),
    ("Ephesians", 6),
    ("Philippians", 4),
    ("Colossians", 4),
    ("1 Thessalonians", 5),
    ("2 Thessalonians", 3),
    ("1 Timothy", 6),
    ("2 Timothy", 4),
    ("Titus", 3),
    ("Philemon", 1),
    ("Hebrews", 13),
    ("James", 5),
    ("1 Peter", 5),
    ("2 Peter", 3),
    ("1 John", 5),
    ("2 John", 1),
    ("3 John", 1),
    ("Jude", 1),
    ("Revelation", 22),
]

CANONICAL_BNAMES = [name for name, _ in CANONICAL_BOOKS]
CANONICAL_CHAPTERS_BY_BOOK = {index: chapters for index, (_, chapters) in enumerate(CANONICAL_BOOKS, start=1)}
EXPECTED_BOOK_NUMBERS = set(CANONICAL_CHAPTERS_BY_BOOK.keys())

LANG_HINTS = {
    "english": "ENG",
    "malayalam": "MAL",
    "tamil": "TAM",
    "hindi": "HIN",
    "telugu": "TEL",
    "kannada": "KAN",
    "spanish": "SPA",
    "french": "FRE",
    "german": "GER",
    "portuguese": "POR",
}


def local_name(name: str) -> str:
    if "}" in name:
        name = name.rsplit("}", 1)[1]
    if ":" in name:
        name = name.rsplit(":", 1)[1]
    return name.strip().lower()


def normalize_whitespace(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def parse_csv_option(value: Optional[str], default: Sequence[str]) -> List[str]:
    if value is None:
        return [item.strip().lower() for item in default if item.strip()]
    values = [item.strip().lower() for item in value.split(",") if item.strip()]
    return values if values else [item.strip().lower() for item in default if item.strip()]


class XmlBibleParser:
    DEFAULT_BOOK_TAGS = ("biblebook", "book")
    DEFAULT_CHAPTER_TAGS = ("chapter", "c")
    DEFAULT_VERSE_TAGS = ("vers", "verse", "v")

    DEFAULT_BOOK_NUMBER_ATTRS = ("bnumber", "booknumber", "book_num", "number", "num", "id")
    DEFAULT_CHAPTER_NUMBER_ATTRS = ("cnumber", "chapternumber", "chapter_num", "number", "num", "id")
    DEFAULT_VERSE_NUMBER_ATTRS = ("vnumber", "versenumber", "verse_num", "number", "num", "id")
    DEFAULT_BOOK_NAME_ATTRS = ("bname", "bookname", "name", "title", "short", "abbr")
    DEFAULT_TITLE_ATTRS = ("translation", "biblename", "title", "name")

    def __init__(
        self,
        xml_path: Path,
        book_tags: Sequence[str],
        chapter_tags: Sequence[str],
        verse_tags: Sequence[str],
        book_number_attrs: Sequence[str],
        chapter_number_attrs: Sequence[str],
        verse_number_attrs: Sequence[str],
        book_name_attrs: Sequence[str],
        title_attrs: Sequence[str],
    ):
        self.xml_path = xml_path
        self.book_tags = set(book_tags)
        self.chapter_tags = set(chapter_tags)
        self.verse_tags = set(verse_tags)
        self.book_number_attrs = list(book_number_attrs)
        self.chapter_number_attrs = list(chapter_number_attrs)
        self.verse_number_attrs = list(verse_number_attrs)
        self.book_name_attrs = list(book_name_attrs)
        self.title_attrs = list(title_attrs)

    def parse(self) -> Tuple[List[Tuple[int, int, int, str]], List[str], str]:
        tree = ET.parse(self.xml_path)
        root = tree.getroot()

        metadata_title = self._extract_title(root)
        book_nodes = self._find_book_nodes(root)
        if not book_nodes:
            raise ValueError(
                "No book nodes found. Provide explicit tag mappings via "
                "--book-tags/--chapter-tags/--verse-tags."
            )

        verses_map: Dict[Tuple[int, int, int], str] = {}
        ordered_book_names: List[str] = []

        for fallback_book_number, book_node in enumerate(book_nodes, start=1):
            book_number = self._read_int_attr(book_node, self.book_number_attrs)
            if book_number is None:
                book_number = fallback_book_number

            book_name = self._read_str_attr(book_node, self.book_name_attrs)
            if book_name:
                ordered_book_names.append(book_name)

            chapter_nodes = self._direct_children_by_tags(book_node, self.chapter_tags)
            if not chapter_nodes:
                chapter_nodes = list(self._descendants_by_tags(book_node, self.chapter_tags))

            for fallback_chapter_number, chapter_node in enumerate(chapter_nodes, start=1):
                chapter_number = self._read_int_attr(chapter_node, self.chapter_number_attrs)
                if chapter_number is None:
                    chapter_number = fallback_chapter_number

                verse_nodes = self._direct_children_by_tags(chapter_node, self.verse_tags)
                if not verse_nodes:
                    verse_nodes = list(self._descendants_by_tags(chapter_node, self.verse_tags))

                for fallback_verse_number, verse_node in enumerate(verse_nodes, start=1):
                    verse_number = self._read_int_attr(verse_node, self.verse_number_attrs)
                    if verse_number is None:
                        verse_number = fallback_verse_number

                    verse_text = normalize_whitespace("".join(verse_node.itertext()))
                    key = (book_number, chapter_number, verse_number)
                    prior = verses_map.get(key)
                    if prior is None or (not prior and verse_text):
                        verses_map[key] = verse_text

        if not verses_map:
            raise ValueError("No verses parsed from XML.")

        verses = [(b, c, v, verses_map[(b, c, v)]) for (b, c, v) in sorted(verses_map.keys())]
        return verses, ordered_book_names, metadata_title

    def _extract_title(self, root: ET.Element) -> str:
        attr_map = self._attr_map(root)
        for attr in self.title_attrs:
            value = attr_map.get(attr)
            if value:
                cleaned = normalize_whitespace(value)
                if cleaned:
                    return cleaned
        return self.xml_path.stem

    def _find_book_nodes(self, root: ET.Element) -> List[ET.Element]:
        nodes: List[ET.Element] = []
        for element in root.iter():
            if local_name(element.tag) not in self.book_tags:
                continue

            chapter_children = self._direct_children_by_tags(element, self.chapter_tags)
            if chapter_children:
                nodes.append(element)
                continue

            if any(True for _ in self._descendants_by_tags(element, self.chapter_tags)):
                nodes.append(element)
        return nodes

    def _read_int_attr(self, element: ET.Element, attr_names: Sequence[str]) -> Optional[int]:
        attr_map = self._attr_map(element)
        for attr_name in attr_names:
            value = attr_map.get(attr_name)
            parsed = self._parse_int(value)
            if parsed is not None:
                return parsed
        return None

    def _read_str_attr(self, element: ET.Element, attr_names: Sequence[str]) -> Optional[str]:
        attr_map = self._attr_map(element)
        for attr_name in attr_names:
            value = attr_map.get(attr_name)
            if value:
                cleaned = normalize_whitespace(value)
                if cleaned:
                    return cleaned
        return None

    @staticmethod
    def _parse_int(value: Optional[str]) -> Optional[int]:
        if value is None:
            return None
        text = value.strip()
        if not text:
            return None
        if text.isdigit():
            return int(text)
        match = re.search(r"(\d+)$", text)
        if match:
            return int(match.group(1))
        return None

    @staticmethod
    def _attr_map(element: ET.Element) -> Dict[str, str]:
        return {local_name(key): value for key, value in element.attrib.items()}

    @staticmethod
    def _direct_children_by_tags(element: ET.Element, tags: Sequence[str]) -> List[ET.Element]:
        return [child for child in list(element) if local_name(child.tag) in tags]

    @staticmethod
    def _descendants_by_tags(element: ET.Element, tags: Sequence[str]) -> Iterable[ET.Element]:
        for child in element.iter():
            if child is element:
                continue
            if local_name(child.tag) in tags:
                yield child


def infer_lang_code(text_sources: Sequence[str]) -> str:
    joined = " ".join(text_sources).lower()
    for token, code in LANG_HINTS.items():
        if token in joined:
            return code
    return "UNK"


def infer_translation_code(text_sources: Sequence[str]) -> str:
    for source in text_sources:
        for match in re.findall(r"[A-Z]{3,6}", source.upper()):
            if match in {"BIBLE", "HOLY", "TEXT", "VERSION"}:
                continue
            return match

    merged = "_".join(text_sources)
    cleaned = re.sub(r"[^A-Za-z0-9]+", "_", merged).upper().strip("_")
    cleaned = "".join(ch for ch in cleaned if ch.isalnum())
    if len(cleaned) < 3:
        cleaned = (cleaned + "XML")[:3]
    return cleaned[:6]


def derive_output_path(
    input_xml: Path,
    output_path: Optional[Path],
    lang_code: Optional[str],
    translation_code: Optional[str],
    metadata_title: str,
) -> Path:
    if output_path is not None:
        return output_path

    inferred_lang = (lang_code or infer_lang_code([metadata_title, input_xml.stem])).upper()
    inferred_translation = (translation_code or infer_translation_code([metadata_title, input_xml.stem])).upper()
    return input_xml.with_name(f"{inferred_lang}_{inferred_translation}.bible")


def validate_output_file_name(output_path: Path) -> None:
    if not FILE_NAME_PATTERN.match(output_path.name):
        raise ValueError(
            f"Output file '{output_path.name}' does not match required pattern "
            "<LANG>_<NAME>.bible (example: ENG_ESV.bible)."
        )


def validate_parsed_for_import(verses: Sequence[Tuple[int, int, int, str]]) -> None:
    by_book: Dict[int, set] = {}
    for book, chapter, _, _ in verses:
        by_book.setdefault(book, set()).add(chapter)

    actual_book_numbers = set(by_book.keys())
    if actual_book_numbers != EXPECTED_BOOK_NUMBERS:
        missing = sorted(EXPECTED_BOOK_NUMBERS - actual_book_numbers)
        extras = sorted(actual_book_numbers - EXPECTED_BOOK_NUMBERS)
        raise ValueError(
            "Book number coverage mismatch for import compatibility. "
            f"Missing={missing} Extra={extras}"
        )

    for book_number, expected_chapters in sorted(CANONICAL_CHAPTERS_BY_BOOK.items()):
        chapters = by_book.get(book_number, set())
        if not chapters:
            raise ValueError(f"Book {book_number} has no chapters.")

        min_chapter = min(chapters)
        max_chapter = max(chapters)
        distinct = len(chapters)
        if min_chapter != 1 or max_chapter != expected_chapters or distinct != expected_chapters:
            raise ValueError(
                "Chapter coverage mismatch for import compatibility: "
                f"book {book_number} expected 1...{expected_chapters}, "
                f"actual min={min_chapter} max={max_chapter} distinct={distinct}."
            )


def write_sqlite(
    output_path: Path,
    verses: Sequence[Tuple[int, int, int, str]],
    title: str,
    overwrite: bool,
) -> None:
    if output_path.exists():
        if not overwrite:
            raise FileExistsError(f"{output_path} already exists. Use --overwrite to replace.")
        output_path.unlink()

    connection = sqlite3.connect(output_path)
    try:
        cursor = connection.cursor()
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS bible (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              bnumber INTEGER,
              cnumber INTEGER,
              vnumber INTEGER,
              verse TEXT
            );
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS bnames (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              bname TEXT
            );
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS meta (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              biblename TEXT,
              title TEXT,
              source TEXT,
              rights TEXT
            );
            """
        )

        cursor.executemany(
            "INSERT INTO bible (id, bnumber, cnumber, vnumber, verse) VALUES (?, ?, ?, ?, ?)",
            [(idx, b, c, v, text) for idx, (b, c, v, text) in enumerate(verses, start=1)],
        )
        cursor.executemany(
            "INSERT INTO bnames (id, bname) VALUES (?, ?)",
            [(index, name) for index, name in enumerate(CANONICAL_BNAMES, start=1)],
        )
        cursor.execute(
            "INSERT INTO meta (biblename, title, source, rights) VALUES (?, ?, ?, ?)",
            (title, title, "", ""),
        )
        connection.commit()
    finally:
        connection.close()


def validate_sqlite_for_import(output_path: Path) -> None:
    connection = sqlite3.connect(output_path)
    try:
        cursor = connection.cursor()

        cursor.execute("PRAGMA table_info(bible);")
        columns = {row[1].lower() for row in cursor.fetchall()}
        required_columns = {"bnumber", "cnumber", "vnumber", "verse"}
        if not required_columns.issubset(columns):
            raise ValueError(f"'bible' table is missing required columns: {sorted(required_columns - columns)}")

        cursor.execute("SELECT COUNT(*) FROM bnames;")
        bnames_count = int(cursor.fetchone()[0])
        if bnames_count != 66:
            raise ValueError(f"'bnames' must contain 66 rows, found {bnames_count}.")

        cursor.execute(
            """
            SELECT bnumber, MIN(cnumber), MAX(cnumber), COUNT(DISTINCT cnumber)
            FROM bible
            GROUP BY bnumber
            ORDER BY bnumber;
            """
        )
        rows = cursor.fetchall()
        stats = {int(row[0]): (int(row[1]), int(row[2]), int(row[3])) for row in rows}

        if set(stats.keys()) != EXPECTED_BOOK_NUMBERS:
            raise ValueError("bnumber coverage is not canonical 1...66.")

        for book_number, expected_chapters in sorted(CANONICAL_CHAPTERS_BY_BOOK.items()):
            min_chapter, max_chapter, distinct_count = stats[book_number]
            if min_chapter != 1 or max_chapter != expected_chapters or distinct_count != expected_chapters:
                raise ValueError(
                    f"Chapter coverage mismatch in output DB for book {book_number}: "
                    f"expected 1...{expected_chapters}, got min={min_chapter}, max={max_chapter}, distinct={distinct_count}."
                )
    finally:
        connection.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Convert Bible XML to ViewTheWord-compatible .bible SQLite format."
    )
    parser.add_argument("xml_file", help="Input Bible XML file")
    parser.add_argument("--output", help="Output .bible file path")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite output if it exists")

    parser.add_argument("--lang-code", help="3-letter language code for generated filename (e.g. ENG)")
    parser.add_argument("--translation-code", help="3-6 letter translation code for generated filename (e.g. ESV)")

    parser.add_argument(
        "--book-tags",
        help="Comma-separated book tag names (default: BIBLEBOOK,book)",
    )
    parser.add_argument(
        "--chapter-tags",
        help="Comma-separated chapter tag names (default: CHAPTER,chapter,c)",
    )
    parser.add_argument(
        "--verse-tags",
        help="Comma-separated verse tag names (default: VERS,verse,v)",
    )
    parser.add_argument(
        "--book-number-attrs",
        help="Comma-separated book number attribute names",
    )
    parser.add_argument(
        "--chapter-number-attrs",
        help="Comma-separated chapter number attribute names",
    )
    parser.add_argument(
        "--verse-number-attrs",
        help="Comma-separated verse number attribute names",
    )
    parser.add_argument(
        "--book-name-attrs",
        help="Comma-separated book name attribute names",
    )
    parser.add_argument(
        "--title-attrs",
        help="Comma-separated root title attribute names",
    )
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    xml_path = Path(args.xml_file).expanduser().resolve()
    if not xml_path.exists():
        print(f"error: input file not found: {xml_path}", file=sys.stderr)
        return 1

    output_path_arg = Path(args.output).expanduser().resolve() if args.output else None

    xml_parser = XmlBibleParser(
        xml_path=xml_path,
        book_tags=parse_csv_option(args.book_tags, XmlBibleParser.DEFAULT_BOOK_TAGS),
        chapter_tags=parse_csv_option(args.chapter_tags, XmlBibleParser.DEFAULT_CHAPTER_TAGS),
        verse_tags=parse_csv_option(args.verse_tags, XmlBibleParser.DEFAULT_VERSE_TAGS),
        book_number_attrs=parse_csv_option(args.book_number_attrs, XmlBibleParser.DEFAULT_BOOK_NUMBER_ATTRS),
        chapter_number_attrs=parse_csv_option(args.chapter_number_attrs, XmlBibleParser.DEFAULT_CHAPTER_NUMBER_ATTRS),
        verse_number_attrs=parse_csv_option(args.verse_number_attrs, XmlBibleParser.DEFAULT_VERSE_NUMBER_ATTRS),
        book_name_attrs=parse_csv_option(args.book_name_attrs, XmlBibleParser.DEFAULT_BOOK_NAME_ATTRS),
        title_attrs=parse_csv_option(args.title_attrs, XmlBibleParser.DEFAULT_TITLE_ATTRS),
    )

    try:
        verses, _, title = xml_parser.parse()
        validate_parsed_for_import(verses)

        output_path = derive_output_path(
            input_xml=xml_path,
            output_path=output_path_arg,
            lang_code=args.lang_code,
            translation_code=args.translation_code,
            metadata_title=title,
        )
        validate_output_file_name(output_path)
        write_sqlite(output_path, verses=verses, title=title, overwrite=args.overwrite)
        validate_sqlite_for_import(output_path)
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(f"{xml_path} -> {output_path}")
    print("Import checks: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
