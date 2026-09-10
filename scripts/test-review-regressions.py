#!/usr/bin/env python3
"""Run converter and release-preflight regressions entirely in temporary directories."""
import importlib.util
import base64
import re
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

    def test_version_configuration_matches_source(self):
        version = (ROOT / "VERSION").read_text().strip()
        config = (ROOT / "Config/Version.xcconfig").read_text()
        self.assertEqual(re.search(r"^MARKETING_VERSION = (.+)$", config, re.M)[1], version)


class ReleasePreflightTests(unittest.TestCase):
    def test_dirty_untracked_and_wrong_tag_sources_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True).strip()
            def verify():
                return subprocess.run([str(ROOT / "scripts/verify-release-source.sh"), "v1.0.0"], cwd=directory, text=True, capture_output=True)
            git("init", "--quiet")
            git("config", "user.name", "Regression Test")
            git("config", "user.email", "test@example.invalid")
            path = Path(directory) / "source.txt"
            path.write_text("original")
            git("add", "."); git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
            git("-c", "tag.gpgsign=false", "tag", "v1.0.0")
            self.assertEqual(verify().stdout.strip(), git("rev-parse", "HEAD"))
            path.write_text("dirty")
            self.assertNotEqual(verify().returncode, 0)
            path.write_text("original")
            stray = Path(directory) / "untracked.txt"; stray.write_text("untracked")
            self.assertNotEqual(verify().returncode, 0)
            stray.unlink()
            path.write_text("new commit")
            git("add", "."); git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "newer")
            self.assertNotEqual(verify().returncode, 0)


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
