#!/usr/bin/env python3
"""Exercise release orchestration with real temporary Git repos and offline tool doubles."""
import argparse
import importlib.util
import io
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseFlowTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="ViewTheWord release ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "ViewTheWord").mkdir()
        shutil.copy2(ROOT / "ViewTheWord/Info.plist", self.root / "ViewTheWord/Info.plist")
        (self.root / "VERSION").write_text("4.0.1\n")
        (self.root / ".gitignore").write_text("build/\n")
        self.git("init", "--quiet")
        self.git("config", "user.name", "Release Regression")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "tag.gpgsign", "false")
        self.git("remote", "add", "origin", "https://github.com/sukujgrg/ViewTheWord.git")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
        self.commit = self.git("rev-parse", "HEAD")
        self.calls = []
        self.remote_tag = None
        self.existing_release = False
        self.conclusions = ["success"]
        self.ci_sha = self.commit
        self.ci_branch = "master"
        self.ci_event = "push"
        self.ci_status = "completed"
        self.missing_runs = 0
        self.pushed = True
        self.notary_status = "Accepted"
        self.fail_feed = False
        self.after_archive = lambda: None
        self.latest = None
        self.latest_reads = 0
        self.latest_changed = False
        self.actual_run = release.run
        self.addCleanup(patch.stopall)
        patch.object(release, "ROOT", self.root).start()
        patch.object(release, "run", side_effect=self.tool).start()
        patch.object(release, "github", side_effect=self.api).start()
        patch.object(release.platform, "system", return_value="Darwin").start()
        patch.object(release.shutil, "which", side_effect=lambda value: "/usr/bin/" + value).start()
        patch.object(release.time, "sleep").start()
        patch.dict(os.environ, {"CI": "false", "GITHUB_ACTIONS": "false"}).start()
        self.output = io.StringIO()
        self.stdout_context = redirect_stdout(self.output)
        self.stdout_context.__enter__()
        self.addCleanup(self.stdout_context.__exit__, None, None, None)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    def api(self, repo, path, optional=False):
        self.assertEqual(repo, "sukujgrg/ViewTheWord")
        if path.startswith("releases/tags/"):
            return {"id": 1} if self.existing_release else None
        if path.startswith("git/ref/tags/"):
            return {"object": {"type": "commit", "sha": self.remote_tag}} if self.remote_tag else None
        if path.startswith("commits/tags/"):
            if self.remote_tag is None:
                raise release.ReleaseError("GitHub request failed for missing tag (HTTP 422).")
            return {"sha": self.remote_tag}
        if path == "commits/" + self.commit:
            return {"sha": self.commit} if self.pushed else None
        if path == "releases/latest":
            self.latest_reads += 1
            if self.latest_changed and self.latest_reads > 1:
                return {"tag_name": "v4.0.2"}
            return {"tag_name": self.latest} if self.latest else None
        self.fail(f"Unexpected GitHub request: {path}")

    def tool(self, *args, capture=False):
        args = tuple(str(arg) for arg in args)
        self.calls.append(args)
        if args[:3] in (("gh", "run", "list"), ("gh", "run", "view")):
            self.assertIn("--repo", args)
            if args[2] == "list":
                self.assertEqual(args[args.index("--commit") + 1], self.commit)
                self.assertEqual(args[args.index("--workflow") + 1], "validate.yml")
                self.assertEqual(args[args.index("--branch") + 1], "master")
                self.assertEqual(args[args.index("--event") + 1], "push")
                if self.missing_runs:
                    self.missing_runs -= 1
                    return "[]"
            conclusion = self.conclusions.pop(0) if len(self.conclusions) > 1 else self.conclusions[0]
            result = {"databaseId": 123, "headSha": self.ci_sha, "status": self.ci_status,
                      "headBranch": self.ci_branch, "event": self.ci_event,
                      "conclusion": conclusion, "url": "https://github.com/sukujgrg/ViewTheWord/actions/runs/123"}
            self.ci_status = "completed"
            return json.dumps([result] if args[2] == "list" else result)
        if args[:2] == ("git", "push"):
            self.remote_tag = self.git("rev-parse", "refs/tags/v4.0.1^{commit}")
            return
        if args[:3] == ("gh", "release", "create"):
            for artifact in args[4:args.index("--repo")]:
                self.assertTrue(Path(artifact).is_file())
            self.assertEqual(self.remote_tag, self.commit)
            self.existing_release = True
            return
        if args[0] == "git":
            return self.actual_run(*args, capture=capture)
        if args[0] == "xcodebuild":
            if "archive" in args:
                self.assertIn("ARCHS=arm64 x86_64", args)
                self.assertIn("ONLY_ACTIVE_ARCH=NO", args)
                self.assertNotIn("CODE_SIGNING_ALLOWED=NO", args)
                self.assertFalse(any(arg.startswith("MARKETING_VERSION=") for arg in args))
                self.build_number = next(arg.split("=", 1)[1] for arg in args if arg.startswith("CURRENT_PROJECT_VERSION="))
                self.after_archive()
            elif "-exportArchive" in args:
                info = plistlib.loads((self.root / "ViewTheWord/Info.plist").read_bytes())
                info.update(CFBundleShortVersionString="4.0.1", CFBundleVersion=self.build_number,
                            VTWSourceCommit=self.commit, CFBundleExecutable="ViewTheWord")
                app = Path(args[args.index("-exportPath") + 1]) / "ViewTheWord.app/Contents"
                app.mkdir(parents=True)
                (app / "Info.plist").write_bytes(plistlib.dumps(info))
                options = plistlib.loads(Path(args[args.index("-exportOptionsPlist") + 1]).read_bytes())
                self.assertEqual(options["method"], "developer-id")
            return
        if args[0].endswith("generate_keys"):
            return plistlib.loads((self.root / "ViewTheWord/Info.plist").read_bytes())["SUPublicEDKey"]
        if args[0] == "lipo":
            self.assertEqual(args[-3:], ("-verify_arch", "arm64", "x86_64"))
            return
        if args[0] == "ditto":
            if "-k" in args:
                Path(args[-1]).write_bytes(b"fixture archive")
            else:
                shutil.copytree(args[-2], args[-1])
            return
        if args[:3] == ("xcrun", "notarytool", "submit"):
            self.assertEqual(args[args.index("--keychain-profile") + 1], "ViewTheWordNotary")
            return json.dumps({"status": self.notary_status, "id": "fixture-submission"})
        if args[:2] == ("xcrun", "stapler"):
            return
        if len(args) > 1 and args[1].endswith("update-feed.py"):
            if self.fail_feed:
                raise subprocess.CalledProcessError(1, args)
            Path(args[args.index("--output") + 1]).write_text("signed fixture feed")
            return
        self.fail(f"Unexpected command: {args}")

    def invoke(self, **options):
        args = dict(notary_profile="ViewTheWordNotary", notes=None, check=False, no_publish=False)
        args.update(options)
        release.release(argparse.Namespace(**args))

    def assert_not_published(self):
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertIsNone(self.remote_tag)
        self.assertFalse(self.existing_release)

    def test_source_checks_reject_dirty_untracked_and_changed_commits_without_requiring_a_tag(self):
        self.assertEqual(release.source_commit(), self.commit)
        self.assertEqual(release.source_commit(self.commit), self.commit)
        path = self.root / "VERSION"
        path.write_text("4.0.2\n")
        with self.assertRaisesRegex(release.ReleaseError, "clean working tree"):
            self.invoke(check=True)
        path.write_text("4.0.1\n")
        stray = self.root / "untracked.txt"
        stray.write_text("untracked")
        with self.assertRaisesRegex(release.ReleaseError, "clean working tree"):
            self.invoke(check=True)
        stray.unlink()
        path.write_text("4.0.2\n")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "newer")
        with self.assertRaisesRegex(release.ReleaseError, "HEAD changed"):
            release.source_commit(self.commit)
        self.assertFalse(any(call[0] in ("gh", "xcodebuild") for call in self.calls))
        self.assert_not_published()

    def test_complete_flow_validates_then_builds_locally_then_tags_and_publishes(self):
        self.invoke()
        positions = {}
        for index, call in enumerate(self.calls):
            if call[:3] == ("gh", "run", "list"):
                positions.setdefault("ci", index)
            if call[0] == "xcodebuild" and "archive" in call:
                positions["archive"] = index
            for label, prefix in (("notary", ("xcrun", "notarytool", "submit")),
                                  ("staple", ("xcrun", "stapler", "validate")),
                                  ("tag", ("git", "tag")), ("push", ("git", "push")),
                                  ("publish", ("gh", "release", "create"))):
                if call[:len(prefix)] == prefix:
                    positions[label] = index
            if len(call) > 1 and call[1].endswith("update-feed.py"):
                positions["feed"] = index
        self.assertEqual(list(positions), ["ci", "archive", "notary", "staple", "feed", "tag", "push", "publish"])
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual((self.root / "VERSION").read_text(), "4.0.1\n")
        self.assertEqual(self.git("rev-parse", "v4.0.1^{commit}"), self.commit)

    def test_failed_ci_never_starts_signing_or_creates_a_tag(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped", "neutral", None):
            with self.subTest(conclusion=conclusion):
                self.conclusions = [conclusion]
                with self.assertRaises(release.ReleaseError):
                    self.invoke()
                self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))
                self.assert_not_published()

    def test_unpushed_missing_and_wrong_commit_validation_are_rejected(self):
        for kind in ("unpushed", "missing_run", "wrong_commit"):
            with self.subTest(kind=kind):
                self.pushed = kind != "unpushed"
                self.missing_runs = 13 if kind == "missing_run" else 0
                self.ci_sha = "0" * 40 if kind == "wrong_commit" else self.commit
                with self.assertRaises(release.ReleaseError):
                    self.invoke()
                self.assert_not_published()

    def test_newly_pushed_and_running_validation_is_awaited(self):
        self.missing_runs = 1
        self.ci_status = "in_progress"
        self.invoke(check=True)
        self.assertTrue(any(call[:3] == ("gh", "run", "view") for call in self.calls))
        self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))
        self.assert_not_published()

    def test_pr_feature_branch_and_tag_runs_cannot_authorize_release(self):
        for event, branch in (("pull_request", "feature"), ("push", "feature"), ("push", "v4.0.1")):
            with self.subTest(event=event, branch=branch):
                self.ci_event, self.ci_branch = event, branch
                with self.assertRaisesRegex(release.ReleaseError, "master push run"):
                    self.invoke()
                self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))
                self.assert_not_published()

    def test_ci_failure_on_final_recheck_preserves_artifacts_and_does_not_tag(self):
        self.conclusions = ["success", "failure"]
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.assertTrue((self.root / "build/release/v4.0.1/appcast.xml").exists())
        self.assert_not_published()

    def test_notary_or_feed_failure_does_not_tag_or_publish(self):
        for stage in ("notary", "feed"):
            with self.subTest(stage=stage):
                self.notary_status = "Invalid" if stage == "notary" else "Accepted"
                self.fail_feed = stage == "feed"
                with self.assertRaises((release.ReleaseError, subprocess.CalledProcessError)):
                    self.invoke()
                self.assert_not_published()

    def test_source_edit_during_build_does_not_notarize_or_tag(self):
        self.after_archive = lambda: (self.root / "VERSION").write_text("4.0.2\n")
        with self.assertRaisesRegex(release.ReleaseError, "clean working tree"):
            self.invoke()
        self.assertFalse(any(call[:2] == ("xcrun", "notarytool") for call in self.calls))
        self.assert_not_published()

    def test_existing_release_and_moved_remote_tag_are_rejected_before_build(self):
        self.existing_release = True
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.existing_release = False
        self.remote_tag = "0" * 40
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.assertFalse(any(call[0] == "xcodebuild" for call in self.calls))

    def test_existing_matching_tags_are_reused_without_pushing(self):
        self.git("tag", "v4.0.1")
        self.remote_tag = self.commit
        self.invoke()
        self.assertFalse(any(call[:2] in (("git", "tag"), ("git", "push")) for call in self.calls))
        self.assertTrue(self.existing_release)

    def test_changed_latest_release_stops_before_tagging(self):
        self.latest_changed = True
        with self.assertRaises(release.ReleaseError):
            self.invoke()
        self.assert_not_published()

    def test_local_artifact_mode_does_not_tag_or_publish(self):
        self.invoke(no_publish=True)
        self.assertTrue((self.root / "build/release/v4.0.1/appcast.xml").exists())
        self.assert_not_published()

    def test_release_cannot_run_in_ci(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "true"}):
            with self.assertRaisesRegex(release.ReleaseError, "on your Mac"):
                self.invoke()
        self.assertEqual(self.calls, [])

    def test_unsupported_push_destinations_are_rejected(self):
        for origin in ("https://example.invalid/repo.git", "https://github.com/elsewhere/app.git"):
            self.git("remote", "set-url", "origin", origin)
            with self.assertRaises(release.ReleaseError):
                self.invoke()
        self.assert_not_published()


class GitHubTransportTests(unittest.TestCase):
    def test_only_confirmed_404_is_treated_as_absent(self):
        for status, body, exit_code in ((200, '{"sha":"fixture"}', 0), (404, '{}', 1),
                                        (403, '{}', 1), (422, '{}', 1), (500, '{}', 1), (None, '', 1)):
            with self.subTest(status=status):
                output = f"HTTP/2.0 {status} status\ncontent-type: application/json\n\n{body}" if status else ""
                response = subprocess.CompletedProcess([], exit_code, output, "failure" if exit_code else "")
                with patch.object(release.subprocess, "run", return_value=response):
                    if status == 200:
                        self.assertEqual(release.github("owner/repo", "commits/main", optional=True), {"sha": "fixture"})
                    elif status == 404:
                        self.assertIsNone(release.github("owner/repo", "commits/main", optional=True))
                        with self.assertRaises(release.ReleaseError):
                            release.github("owner/repo", "commits/main")
                    else:
                        with self.assertRaises(release.ReleaseError):
                            release.github("owner/repo", "commits/main", optional=True)

    def test_missing_tag_uses_ref_lookup_without_resolving_a_commit(self):
        def request(args, **kwargs):
            path = args[-1]
            if path == "repos/owner/repo/git/ref/tags/v4.0.1":
                return subprocess.CompletedProcess(args, 1, 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}', "")
            self.fail(f"A missing tag must not reach the commit endpoint, which returns 422: {path}")

        with patch.object(release.subprocess, "run", side_effect=request) as transport:
            self.assertIsNone(release.remote_tag_commit("owner/repo", "v4.0.1"))
            self.assertEqual(transport.call_count, 1)

    def test_existing_lightweight_and_annotated_tags_resolve_to_the_commit(self):
        for kind, object_sha in (("commit", "commit-sha"), ("tag", "annotated-tag-sha")):
            with self.subTest(kind=kind):
                def request(args, **kwargs):
                    path = args[-1]
                    if path == "repos/owner/repo/git/ref/tags/v4.0.1":
                        data = {"object": {"type": kind, "sha": object_sha}}
                    elif path == "repos/owner/repo/commits/tags/v4.0.1":
                        data = {"sha": "commit-sha"}
                    else:
                        self.fail(f"Unexpected tag request: {path}")
                    return subprocess.CompletedProcess(args, 0, "HTTP/2.0 200 OK\n\n" + json.dumps(data), "")

                with patch.object(release.subprocess, "run", side_effect=request):
                    self.assertEqual(release.remote_tag_commit("owner/repo", "v4.0.1"), "commit-sha")

    def test_tag_lookup_errors_and_disappearance_abort(self):
        for code in (403, 422, 500):
            for during_resolution in (False, True):
                with self.subTest(code=code, during_resolution=during_resolution):
                    def request(args, **kwargs):
                        if during_resolution and "/git/ref/" in args[-1]:
                            body = json.dumps({"object": {"type": "commit", "sha": "commit-sha"}})
                            return subprocess.CompletedProcess(args, 0, "HTTP/2.0 200 OK\n\n" + body, "")
                        return subprocess.CompletedProcess(args, 1, f'HTTP/2.0 {code} Error\n\n{{"message":"Failed"}}', "")

                    with patch.object(release.subprocess, "run", side_effect=request):
                        with self.assertRaises(release.ReleaseError):
                            release.remote_tag_commit("owner/repo", "v4.0.1")

    def test_automatic_build_number_advances_past_future_published_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / "appcast.xml"
            feed.write_text('''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
                <item><sparkle:version>99991231235959</sparkle:version></item>
                <item><enclosure sparkle:version="99991231235960.2"/></item></channel></rss>''')
            self.assertEqual(release.next_build_number(feed), "99991231235961")


if __name__ == "__main__":
    unittest.main()
