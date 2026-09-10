#!/usr/bin/env python3
"""Build, sign, notarize, and publish ViewTheWord from the maintainer's Mac."""
import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
PROJECT = "ViewTheWord.xcodeproj"
APP_NAME = "ViewTheWord"
RELEASE_BRANCH = "master"
KEY_ACCOUNT = "suku.ViewTheWord"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class ReleaseError(Exception):
    pass


def run(*args, capture=False):
    result = subprocess.run([str(arg) for arg in args], cwd=ROOT, text=True,
                            check=True, stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def github(repo, path, optional=False):
    """Only a confirmed HTTP 404 means absent; network/auth failures must stop."""
    result = subprocess.run(["gh", "api", "--include", f"repos/{repo}/{path}"],
                            cwd=ROOT, text=True, capture_output=True)
    status = re.match(r"HTTP/\S+ (\d+)", result.stdout)
    code = int(status[1]) if status else None
    if optional and code == 404:
        return None
    if result.returncode or code != 200:
        raise ReleaseError(f"GitHub request failed for {path} (HTTP {code or 'unavailable'}). "
                           "Check gh authentication and network access, then retry.")
    return json.loads(result.stdout.split("\n\n", 1)[1])


def source_commit(expected=None):
    if run("git", "status", "--porcelain", "--untracked-files=normal", capture=True):
        raise ReleaseError("Release requires a clean working tree, including untracked files.")
    try:
        commit = run("git", "rev-parse", "--verify", "HEAD^{commit}", capture=True)
    except subprocess.CalledProcessError as error:
        raise ReleaseError("Commit the release source before building.") from error
    if expected is not None and commit != expected:
        raise ReleaseError("HEAD changed during the release. Retry from the intended commit.")
    return commit


def release_repository():
    # Push to the exact URL we checked, including repositories using a pushurl.
    origin = run("git", "remote", "get-url", "--push", "--all", "origin", capture=True)
    match = re.fullmatch(r"(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)"
                         r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?", origin)
    if not match:
        raise ReleaseError("origin must have one GitHub push URL (HTTPS or SSH).")
    return match[1], origin


def verify_ci(repo, commit):
    """Require the newest Validate push run on master for this exact source commit."""
    if github(repo, f"commits/{commit}", optional=True) is None:
        raise ReleaseError(f"Commit and merge or push this source to {RELEASE_BRANCH} before running make release.")
    fields = "databaseId,headSha,headBranch,event,status,conclusion,url"
    expected_source = {"headSha": commit, "headBranch": RELEASE_BRANCH, "event": "push"}
    for attempt in range(13):
        runs = json.loads(run("gh", "run", "list", "--repo", repo, "--workflow", "validate.yml",
                              "--commit", commit, "--branch", RELEASE_BRANCH, "--event", "push", "--limit", "1",
                              "--json", fields, capture=True))
        if runs:
            break
        if attempt == 12:
            raise ReleaseError(f"No Validate push run on {RELEASE_BRANCH} was found for this commit. "
                               f"Merge or push the release changes to {RELEASE_BRANCH}, update your local checkout, and retry.")
        if attempt == 0:
            print("Waiting for GitHub to start Validate for this commit…", flush=True)
        time.sleep(5)
    result = runs[0]
    if any(result.get(key) != value for key, value in expected_source.items()):
        raise ReleaseError(f"Releases require a {RELEASE_BRANCH} push run for this exact source commit.")
    print(f"Validation: {result['url']}", flush=True)
    if result["status"] != "completed":
        # Poll through gh so classic and fine-grained credentials both work.
        deadline = time.monotonic() + 3600
        print("Waiting for Validate to finish…", flush=True)
        while result["status"] != "completed":
            if time.monotonic() >= deadline:
                raise ReleaseError("Validate has not completed after one hour. Retry once it finishes.")
            time.sleep(10)
            result = json.loads(run("gh", "run", "view", str(result["databaseId"]), "--repo", repo,
                                    "--json", fields, capture=True))
    if any(result.get(key) != value for key, value in expected_source.items()) or result["conclusion"] != "success":
        raise ReleaseError(f"Validate did not pass for this commit ({result['conclusion']}). "
                           f"Fix the failure before releasing: {result['url']}")


def remote_tag_commit(repo, tag):
    # Missing refs return 404 here; the commit endpoint returns 422 instead.
    name = quote(tag, safe="")
    if github(repo, f"git/ref/tags/{name}", optional=True) is None:
        return None
    # Resolve the existing ref to a commit, including annotated tags.
    return github(repo, f"commits/tags/{name}")["sha"]


def verify_destination(repo, tag, commit):
    if github(repo, f"releases/tags/{quote(tag, safe='')}", optional=True) is not None:
        raise ReleaseError(f"A release already exists for {tag}. Bump VERSION; releases are never overwritten.")
    local = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{tag}^{{commit}}"],
                           cwd=ROOT, text=True, capture_output=True)
    if local.returncode == 0 and local.stdout.strip() != commit:
        raise ReleaseError(f"Local tag {tag} points to another commit. Choose a new VERSION.")
    if local.returncode not in (0, 1):
        raise ReleaseError(f"Could not inspect local tag {tag}.")
    remote = remote_tag_commit(repo, tag)
    if remote is not None and remote != commit:
        raise ReleaseError(f"GitHub tag {tag} points to another commit. Choose a new VERSION.")
    return local.returncode == 0, remote is not None


def latest_tag(repo):
    release = github(repo, "releases/latest", optional=True)
    return release["tag_name"] if release else None


def next_build_number(previous):
    build = int(datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"))
    if previous:
        for item in ET.parse(previous).findall("./channel/item"):
            enclosure = item.find("enclosure")
            value = item.findtext(SPARKLE + "version")
            if not value and enclosure is not None:
                value = enclosure.get(SPARKLE + "version")
            if not value or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
                raise ReleaseError("The previous appcast contains an invalid build number.")
            build = max(build, int(value.split(".")[0]) + 1)
    return str(build)


def build_artifacts(repo, version, tag, commit, previous_tag, args):
    for tool in ("xcodebuild", "xcrun", "ditto", "lipo"):
        if not shutil.which(tool):
            raise ReleaseError(f"Missing {tool}. Install/select Xcode on this Mac.")
    print(f"Building {APP_NAME} {version} on this Mac…", flush=True)
    run("xcodebuild", "-resolvePackageDependencies", "-project", PROJECT,
        "-scheme", APP_NAME, "-derivedDataPath", "build/DerivedData")
    sparkle = ROOT / "build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
    source_info = plistlib.loads((ROOT / "ViewTheWord/Info.plist").read_bytes())
    if run(sparkle / "generate_keys", "--account", KEY_ACCOUNT, "-p", capture=True) != source_info["SUPublicEDKey"]:
        raise ReleaseError("The Keychain signing key differs from Info.plist. See docs/self-updates.md.")
    with tempfile.TemporaryDirectory(prefix="ViewTheWordRelease-") as directory:
        temp = Path(directory)
        previous = None
        if previous_tag:
            release = github(repo, f"releases/tags/{quote(previous_tag, safe='')}")
            if any(asset["name"] == "appcast.xml" for asset in release["assets"]):
                run("gh", "release", "download", previous_tag, "--repo", repo,
                    "--pattern", "appcast.xml", "--dir", temp)
                previous = temp / "appcast.xml"
                run(sparkle / "sign_update", "--account", KEY_ACCOUNT, "--verify", previous)
        build = next_build_number(previous)
        archive = temp / f"{APP_NAME}.xcarchive"
        source_commit(commit)
        run("xcodebuild", "-project", PROJECT, "-scheme", APP_NAME, "-configuration", "Release",
            "-derivedDataPath", "build/DerivedData", "-archivePath", archive, "archive",
            "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "SKIP_INSTALL=NO",
            "STRIP_INSTALLED_PRODUCT=YES", "COPY_PHASE_STRIP=YES",
            f"CURRENT_PROJECT_VERSION={build}", f"VTW_SOURCE_COMMIT={commit}")
        source_commit(commit)
        export_options = temp / "exportOptions.plist"
        export_options.write_bytes(plistlib.dumps({"method": "developer-id", "signingStyle": "automatic",
                                                   "stripSwiftSymbols": True, "compileBitcode": False}))
        run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", temp / "export",
            "-exportOptionsPlist", export_options)
        app = temp / "export" / f"{APP_NAME}.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        expected = {"CFBundleShortVersionString": version, "CFBundleVersion": build, "VTWSourceCommit": commit}
        if any(info.get(key) != value for key, value in expected.items()):
            raise ReleaseError("The exported app's version/build/source does not match the verified source.")
        run("lipo", app / "Contents/MacOS" / info["CFBundleExecutable"], "-verify_arch", "arm64", "x86_64")
        notary_zip = temp / "notarize.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, notary_zip)
        print("Submitting to Apple for notarization…", flush=True)
        response = json.loads(run("xcrun", "notarytool", "submit", notary_zip,
                                  "--keychain-profile", args.notary_profile, "--wait", "--output-format", "json",
                                  capture=True))
        if response.get("status") != "Accepted":
            raise ReleaseError(f"Notarization was not accepted (submission {response.get('id', 'unknown')}).")
        run("xcrun", "stapler", "staple", app)
        run("xcrun", "stapler", "validate", app)
        output = ROOT / "build/release" / tag
        output.mkdir(parents=True, exist_ok=True)
        final_app = output / app.name
        if final_app.exists():
            shutil.rmtree(final_app)
        run("ditto", app, final_app)
        final_zip = output / f"{APP_NAME}-{version}-notarized.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, final_zip)
        checksum = final_zip.with_suffix(".zip.sha256")
        checksum.write_text(f"{hashlib.sha256(final_zip.read_bytes()).hexdigest()}  {final_zip.name}\n")
        metadata = final_zip.with_suffix(".zip.source.txt")
        metadata.write_text(f"source_commit={commit}\ntag={tag}\nversion={version}\nbuild={build}\n")
        feed = output / "appcast.xml"
        command = [sys.executable, ROOT / "scripts/update-feed.py", "--app", app, "--archive", final_zip,
                   "--output", feed, "--repo", repo, "--tag", tag, "--sparkle-bin", sparkle]
        if previous:
            command.extend(["--previous", previous])
        run(*command)
        return [final_zip, checksum, metadata, feed]


def publish(repo, origin, version, tag, commit, previous_tag, artifacts, notes):
    source_commit(commit)
    verify_ci(repo, commit)
    local_exists, remote_exists = verify_destination(repo, tag, commit)
    if latest_tag(repo) != previous_tag:
        raise ReleaseError("The latest release changed during the build. Retry to include its current update feed.")
    if remote_exists:
        if not local_exists:
            run("git", "fetch", "--no-tags", origin, f"refs/tags/{tag}:refs/tags/{tag}")
    else:
        if not local_exists:
            run("git", "tag", "-a", tag, commit, "-m", f"{APP_NAME} {version}")
        run("git", "push", origin, f"refs/tags/{tag}:refs/tags/{tag}")
    if remote_tag_commit(repo, tag) != commit:
        raise ReleaseError("The GitHub tag changed before publication.")
    source_commit(commit)
    command = ["gh", "release", "create", tag, *artifacts, "--repo", repo, "--verify-tag", "--latest",
               "--title", f"{APP_NAME} {version}"]
    if notes:
        command.extend(["--notes-file", notes])
    else:
        command.extend(["--notes", f"Notarized release {version} from source commit {commit}"])
    run(*command)


def release(args):
    if platform.system() != "Darwin" or any(os.environ.get(key, "").lower() in ("true", "1", "yes")
                                            for key in ("CI", "GITHUB_ACTIONS")):
        raise ReleaseError("Run releases on your Mac, outside CI. Signing credentials stay in your local Keychain.")
    for tool in ("git", "gh"):
        if not shutil.which(tool):
            raise ReleaseError(f"Install {tool} before releasing.")
    commit = source_commit()
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ReleaseError("VERSION must contain one numeric X.Y.Z version.")
    tag = f"v{version}"
    repo, origin = release_repository()
    info = plistlib.loads((ROOT / "ViewTheWord/Info.plist").read_bytes())
    if info["SUFeedURL"] != f"https://github.com/{repo}/releases/latest/download/appcast.xml":
        raise ReleaseError("origin's push repository differs from the app's update feed.")
    if args.notes:
        args.notes = args.notes.resolve()
        if not args.notes.is_file():
            raise ReleaseError(f"Release notes file does not exist: {args.notes}")
    verify_destination(repo, tag, commit)
    verify_ci(repo, commit)
    source_commit(commit)
    print(f"Release source ready: {tag} at {commit}", flush=True)
    if args.check:
        return
    previous_tag = latest_tag(repo)
    artifacts = build_artifacts(repo, version, tag, commit, previous_tag, args)
    source_commit(commit)
    print(f"Signed artifacts: {artifacts[0].parent}", flush=True)
    if not args.no_publish:
        publish(repo, origin, version, tag, commit, previous_tag, artifacts, args.notes)
        print(f"Release complete: https://github.com/{repo}/releases/tag/{tag}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notary-profile", default="ViewTheWordNotary", help="local Keychain profile (default: ViewTheWordNotary)")
    parser.add_argument("--notes", type=Path, help="optional release notes file")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--check", action="store_true", help="only verify source, destination, and CI; do not build or publish")
    modes.add_argument("--no-publish", action="store_true", help="create signed artifacts locally without tagging or publishing")
    try:
        release(parser.parse_args())
    except (ReleaseError, OSError, ValueError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")
    except KeyboardInterrupt:
        parser.exit(130, "Release interrupted. Existing releases and tags were not overwritten.\n")
