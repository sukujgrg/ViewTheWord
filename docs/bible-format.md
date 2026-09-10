# Bible translation format

Files use the case-sensitive name `<LANG>_<NAME>.bible`: a three-letter uppercase language code and a three-to-six-letter uppercase translation code, for example `ENG_UKJV.bible` or `MAL_BSI.bible`.

A file must be a valid SQLite database with:

- A `bible` table containing `bnumber`, `cnumber`, `vnumber`, and `verse`. Column order is arbitrary. Additional columns, including `id`, are optional.
- Integer verse coordinates. Book numbers cover the canonical 66 books, chapter numbers cover each book's canonical chapters, and verse numbers are positive signed 32-bit integers. Each coordinate is unique. Verse numbering need not be identical across translations, and omitted/empty verse text is allowed.
- Text values in `verse` and a `bnames` table with 66 rows. The app maps canonical names by book number; `bnames` names do not determine ordering.

Import checks database integrity and every coordinate before installation. SQLite backup includes committed WAL content, then the private copy is switched to standalone journal mode, validated, indexed on `(bnumber, cnumber, vnumber)`, and installed atomically. The source file is untouched. Read-only permissions are applied on a best-effort basis. Duplicate imports require an explicit Replace action; failed replacements preserve the previous copy.

To convert supported Bible XML:

```bash
python3 scripts/xml-to-bible.py input.xml --lang-code ENG --translation-code TEST --output ENG_TEST.bible
```

Use `--help` to customize XML tag/attribute names. Use `--overwrite` only when intending to replace an existing output. Conversion validates coordinates and canonical coverage, writes and validates a temporary database, and publishes it atomically. A failed conversion preserves existing output.

The included databases have a unique coordinate index. Search uses Unicode-aware whole-word matching, including combining marks and joiners, and escaped literal LIKE patterns for phrases. It does not require an FTS extension or network service.
