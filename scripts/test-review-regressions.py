#!/usr/bin/env python3
"""Run converter and release-preflight regressions entirely in temporary directories."""
import importlib.util
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


if __name__ == "__main__":
    unittest.main()
