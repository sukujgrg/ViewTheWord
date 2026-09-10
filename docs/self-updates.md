# Self-updates

ViewTheWord uses Sparkle 2.9.6 to install releases from GitHub. It keeps App
Sandbox enabled and uses Sparkle's installer and downloader XPC services, so the
app does not need general outgoing network access or a user-data migration.

## App behavior

- **View The Word → Check for Updates…** checks on demand and presents download,
  installation, error, and up-to-date messages using Sparkle's native UI.
- **Automatically Check for Updates** controls Sparkle's persisted checking
  preference. It defaults to enabled, with Sparkle's daily schedule.
- A scheduled check only adds an **Update** button to the passage toolbars.
  It does not open a dialog or take keyboard focus, including during projection.
  Clicking the button opens the update window. Skipping/dismissing the update
  clears the reminder when Sparkle finishes the session.
- Download and restart require the user's install action. Automatic installation
  is disabled. Navigation and live projection continue until normal application
  termination; the existing AppDelegate performs shared projection shutdown.
- One `AppUpdateController` belongs to `AppDelegate`. Every passage window shares
  it. Closing or detaching a passage cannot cancel the application updater.

The feed URL is
`https://github.com/sukujgrg/ViewTheWord/releases/latest/download/appcast.xml`.
Both the feed and the update archive require Ed25519 signatures. The app's public
key is committed in `ViewTheWord/Info.plist`. Sparkle also validates the downloaded
application before replacing the installed copy and handles sandbox permissions
and relaunch.

## Signing key

The update signing key is stored in the maintainer's macOS login Keychain
under the Sparkle account **suku.ViewTheWord**. The private key is not in this
repository. Preserve it when moving to another release machine. Use Sparkle's
documented export/import procedure and store any backup securely outside the
repository. Do not generate a replacement key for each release.

Resolve the pinned tools and display the existing public key:

```bash
xcodebuild -resolvePackageDependencies -project ViewTheWord.xcodeproj \
  -scheme ViewTheWord -derivedDataPath build/DerivedData
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account suku.ViewTheWord -p
```

The release script fails if the Keychain public key differs from `SUPublicEDKey`.
On a new machine, import the existing private key before running a release.

## Publishing

Edit `VERSION`, commit and merge or push the changes to `master`, then update your
local `master` checkout and run `make release` on your Mac. The command requires a
clean checkout and a successful **Validate** push run on `master` for that exact
commit before starting a release build. PR checks validate the proposed merge;
feature-branch pushes and release tags do not trigger duplicate CI. Signing and
notarization run locally with your Keychain credentials; GitHub Actions only
tests unsigned builds.

The command resolves Sparkle, verifies the signing key, archives a universal app,
notarizes and staples it, then creates and verifies the signed feed for the final
zip. After rechecking the source, CI, and latest release, it creates and pushes
`v<VERSION>`. GitHub publication uploads `appcast.xml` alongside the zip, checksum,
and source metadata, and marks that release as latest. Existing tags are reused
only when they point to the same source commit. Existing releases are never
overwritten. Artifacts remain in `build/release/v<VERSION>/` if publication fails.

`scripts/update-feed.py` checks the bundle identity, embedded feed URL and public
key, archive signature and length, app/build versions, and minimum macOS version.
It generates from an isolated directory containing only this release's archive.
When publishing, it retains previous feed entries for older macOS versions and
rejects build numbers that would prevent installed copies from seeing the update.
Current releases require macOS 26.0 or later; the feed takes this minimum from
the built app's `LSMinimumSystemVersion`.

Sparkle compares `CFBundleVersion`. The release command chooses a numeric UTC
timestamp (`YYYYMMDDHHMMSS`) and raises it above prior published builds when
needed. The previous feed is signature-verified before its build numbers are
used. The marketing version comes only from `VERSION`; the tag is derived from
it. There are no manual version/build overrides or validation bypasses.

`make release-check` checks source, destination, and CI without building or
publishing. `make release-notarize` follows the same validated local signing
process and saves the artifacts without creating a tag or GitHub release.

The first release containing this feature must be installed manually by existing
users. That release also establishes the feed; subsequent releases can be
installed from inside ViewTheWord. Until the first feed is published, manual
checks report that the update information could not be retrieved.

## Verification

The Swift package exercises the shared controller using an injected driver,
without checking the internet or starting an installer. Native tests cover menu
enablement, the automatic-check preference, reminders in multiple windows,
focus preservation, and shared live output when a window closes. Python
regressions reject older builds and feed/archive metadata mismatches.
`scripts/test-release-workflow.py` exercises release ordering and failure paths
using temporary Git repositories and offline command doubles; it never signs,
notarizes, pushes to GitHub, or publishes a real release.

Before publishing a release, use a signed and notarized pair of builds in
a disposable installation to check the complete download/install/relaunch flow,
including a read-only install location, a corrupted download, a disconnected
network, and updates while live projection is active. Verify bookmarks, history,
preferences, and imported Bibles after relaunch. Do not use a live presentation
installation for this check.

References: [Sparkle sandbox integration](https://sparkle-project.org/documentation/sandboxing/),
[gentle update reminders](https://sparkle-project.org/documentation/gentle-reminders/),
[publishing signed updates](https://sparkle-project.org/documentation/publishing/).
