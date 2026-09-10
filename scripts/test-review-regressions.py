#!/usr/bin/env python3
"""Run converter, version, and update-feed regressions in temporary directories."""
import importlib.util
import base64
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("converter", ROOT / "scripts/xml-to-bible.py")
converter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(converter)
update_spec = importlib.util.spec_from_file_location("update_feed", ROOT / "scripts/update-feed.py")
update_feed = importlib.util.module_from_spec(update_spec)
update_spec.loader.exec_module(update_feed)


class ConverterTests(unittest.TestCase):
    def test_failed_overwrite_keeps_original_and_success_is_indexed(self):
        verses = [(book, chapter, 1, "fixture") for book, (_, count) in enumerate(converter.CANONICAL_BOOKS, start=1) for chapter in range(1, count + 1)]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "ENG_TST.bible"
            converter.write_sqlite(output, verses, "test", False)
            original = output.read_bytes()
            with self.assertRaises(ValueError):
                converter.write_sqlite(output, verses + [verses[0]], "invalid", True)
            self.assertEqual(output.read_bytes(), original)
            with sqlite3.connect(output) as db:
                plan = db.execute("EXPLAIN QUERY PLAN SELECT verse FROM bible WHERE bnumber=43 AND cnumber=3 AND vnumber=1").fetchone()[3]
                self.assertIn("vtw_verse_coordinates", plan)
            converter.write_sqlite(output, [(b, c, v, "replacement") for b, c, v, _ in verses], "test", True)
            with sqlite3.connect(output) as db:
                self.assertEqual(db.execute("SELECT verse FROM bible LIMIT 1").fetchone()[0], "replacement")
            self.assertEqual([p.name for p in Path(directory).iterdir()], ["ENG_TST.bible"])


class VersionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ViewTheWord version ")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.version = self.directory / "VERSION"
        self.version.write_text((ROOT / "VERSION").read_text())
        self.template = self.directory / "Source Info.plist"
        self.template.write_bytes((ROOT / "ViewTheWord/Info.plist").read_bytes())
        self.output = self.directory / "Derived Files/Info.plist"

    def generate(self, override=None):
        command = ["/bin/bash", str(ROOT / "scripts/generate-info-plist.sh"),
                   str(self.version), str(self.template), str(self.output)]
        if override is not None:
            command.append(override)
        return subprocess.run(command, text=True, capture_output=True)

    def test_version_edits_update_plist_and_preserve_source_metadata(self):
        original_template = self.template.read_bytes()
        for version in (self.version.read_text().strip(), "9.8.7"):
            with self.subTest(version=version):
                self.version.write_text(version + "\n")
                result = self.generate()
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = plistlib.loads(original_template)
                expected["CFBundleShortVersionString"] = version
                self.assertEqual(plistlib.loads(self.output.read_bytes()), expected)
                self.assertEqual(self.version.read_text(), version + "\n")
                self.assertEqual(self.template.read_bytes(), original_template)

    def test_version_override_is_rejected(self):
        original_version = self.version.read_bytes()
        result = self.generate("9.8.6")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())
        self.assertEqual(self.version.read_bytes(), original_version)

    def test_invalid_versions_fail_without_changing_generated_plist(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        original_output = self.output.read_bytes()
        for version in ("", "4.0.x", "1.2.3.4", "4.0.0-preview"):
            with self.subTest(version=version):
                self.version.write_text(version)
                result = self.generate()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("VERSION must contain a numeric", result.stderr)
                self.assertEqual(self.output.read_bytes(), original_output)

    def test_set_version_only_requires_the_version_file(self):
        scripts = self.directory / "scripts"
        scripts.mkdir()
        script = scripts / "set-version.sh"
        shutil.copy2(ROOT / "scripts/set-version.sh", script)
        subprocess.run([str(script), "9.8.5"], check=True)
        self.assertEqual(self.version.read_text(), "9.8.5\n")
        self.assertFalse((self.directory / "Config").exists())


class UpdateFeedTests(unittest.TestCase):
    def test_rejects_older_builds_even_if_marketing_version_is_newer(self):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "appcast.xml"
            feed.write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
                <channel><item><sparkle:version>20260909010101</sparkle:version>
                <sparkle:shortVersionString>3.0.5</sparkle:shortVersionString></item></channel></rss>''')
            for build in ["3", "20260909010101"]:
                with self.assertRaises(ValueError):
                    update_feed.verify_advancing_version({"CFBundleVersion": build, "CFBundleShortVersionString": "3.1.0"}, feed)
            info = {"CFBundleVersion": "20260910010101", "CFBundleShortVersionString": "3.1.0"}
            update_feed.verify_advancing_version(info, feed)
            info["CFBundleShortVersionString"] = "3.0.4"
            with self.assertRaises(ValueError):
                update_feed.verify_advancing_version(info, feed)

    def test_feed_must_match_signed_archive_version_url_length_and_minimum_os(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "ViewTheWord.zip"
            archive.write_bytes(b"fixture")
            feed = Path(directory) / "appcast.xml"
            signature = base64.b64encode(b"s" * 64).decode()
            url = "https://github.com/sukujgrg/ViewTheWord/releases/download/v3.1.0/ViewTheWord.zip"
            xml = f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
                <sparkle:version>20260910</sparkle:version><sparkle:shortVersionString>3.1.0</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
                <enclosure url="{url}" sparkle:edSignature="{signature}" length="7" type="application/octet-stream"/>
                </item></channel></rss>'''
            info = {"CFBundleVersion": "20260910", "CFBundleShortVersionString": "3.1.0", "LSMinimumSystemVersion": "26.0"}
            feed.write_text(xml)
            self.assertEqual(update_feed.verify_feed(feed, info, archive, url), signature)
            for before, after in [(url, "https://example.invalid/other.zip"), ('length="7"', 'length="8"'),
                                  ("26.0", "15.0"), ("3.1.0</", "3.0.5</"), (signature, "")]:
                feed.write_text(xml.replace(before, after))
                with self.assertRaises(ValueError):
                    update_feed.verify_feed(feed, info, archive, url)


if __name__ == "__main__":
    unittest.main()
