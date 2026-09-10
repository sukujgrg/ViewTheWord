# Releasing ViewTheWord

Releases are built, signed, and notarized on the maintainer's Mac using the
existing Developer ID and Sparkle keys in Keychain. GitHub Actions runs
validation only.

## Release from your Mac

1. Edit `VERSION` to the new `X.Y.Z` version, or use `./scripts/set-version.sh 4.0.1`.
2. Commit the release changes and merge the PR into `master`, or push directly to `master`.
3. Update your local `master` checkout and run `make release` from the repository root.

There is no manual tag step: `make release` creates and pushes `v<VERSION>`
after the signed artifacts are ready.

The command requires a clean checkout and waits for the latest **Validate** push
run on `master` for that exact commit to pass. PR validation checks the proposed
merge; the `master` run validates the committed source used for the release.
Preparation builds the universal app, signs with Developer ID, notarizes and
staples it, and generates the signed Sparkle feed. Completed work is saved so
rerunning the command can resume. Only when the artifacts are ready does
publication create and push `v<VERSION>` and create a GitHub draft. It uploads
the zip, checksum, source metadata, and `appcast.xml`, verifies the uploaded
files, then publishes the draft and marks it latest. Existing tags must point
to the same commit; published releases are never overwritten.

`VERSION` is the single source for the app version. An Xcode build phase generates
an intermediate Info.plist in DerivedData, so ordinary Xcode builds and release
builds use the same version automatically. Build numbers are automatic and
increase beyond every build in the previous signed feed. The repository comes
from `origin` and must match the app's update-feed URL.

## Set up a release Mac

The defaults use the existing `ViewTheWordNotary` Keychain profile. On a new
release Mac, configure Xcode signing, authenticate `gh`, and store notarization
credentials once:

```bash
xcrun notarytool store-credentials "ViewTheWordNotary" \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "app-specific-password"
```

The existing Sparkle signing key must also be present on that Mac; see
[self-update signing requirements](self-updates.md#signing-key). Existing
credentials need no setup changes.

## Optional commands

```bash
make release-check                         # Check clean source, destination, and CI; no build or publication
make release NOTES_FILE=release-notes.md    # Supply release notes
make release-notarize                      # Produce signed artifacts locally; no tag or publication
make release-publish                       # Publish saved artifacts; no build, signing, or notarization
```

A different local notary profile can be selected with `NOTARY_PROFILE=ProfileName`.
Version, tag, build-number, and repository overrides are removed; there is no
validation bypass.

## Artifacts and retries

Artifacts are saved under `build/release/v<VERSION>/`: the app, notarized zip,
checksum, source metadata, and signed `appcast.xml`. `state.json` records the
source commit, repository, build number, checksums, and notarization submission.
`work/` retains the Xcode archive, original exported app, submission archive,
and Apple responses. Keep this directory intact until publication completes.
Release builds use `build/ReleaseDerivedData`, separate from ordinary builds.

Usually recovery is simply **rerun the same command**. `make release` calls
preparation and publication; `make release-notarize` calls preparation only;
`make release-publish` requires a complete saved preparation and calls publication
only. The latter needs Git and `gh`, without accessing signing credentials or Apple.

| Interruption | Recovery |
| --- | --- |
| Export fails after archiving | Reuse the verified archive and retry export. |
| Apple's processing takes too long, or waiting disconnects | Wait on the saved submission ID; do not rebuild or submit again. |
| Stapling or feed generation fails | Reuse the completed signing/notarization work and retry the remaining preparation. |
| Draft creation or an upload loses its response | Find the matching draft, verify existing assets, and upload only missing files. An empty failed-upload placeholder can be removed from that draft. |
| Publishing succeeds but its response is lost | Verify the already-published release and report completion without changing it or promoting it to latest again. |

A retry verifies local checksums and rechecks source, CI, tags, and the release
destination. Before publishing, it verifies every remote file by GitHub's SHA-256
digest, or by downloading and hashing it when a digest is unavailable. An
unrelated draft, conflicting asset, changed file, or changed latest release
stops the command. The script never force-pushes tags or overwrites uploaded
files. Only one local release command can run at a time.

### If Apple accepted the upload but no submission ID was saved

The script stops rather than guessing whether to submit again. Look up the
submission for the saved `work/notarize.zip`:

```bash
xcrun notarytool history --keychain-profile "ViewTheWordNotary"
python3 scripts/release.py --no-publish --resume-notarization SUBMISSION_ID
make release-publish
```

The recovery command checks Apple's completed submission log against the saved
archive's SHA-256 before accepting the ID or stapling. A wrong ID cannot authorize
publication. If no submission was accepted, preserve the unfinished directory
elsewhere and start preparation again. Do not edit `state.json` to skip steps.

### If master changes before the release finishes

A prepared release belongs to its recorded commit, even if `master` advances.
To finish that release, check out the recorded commit and rerun the command;
it must still have successful `Validate` push validation from `master`.

To include newer code, prepare from the new validated commit. If no tag or release
exists yet, the same `VERSION` can be used after moving the unfinished release
directory aside. If its tag already points to the old commit, choose a new
`VERSION`. Changing the checkout never silently relabels or reuses an old build.

Unrecorded artifacts from older versions of the script, corrupt state, and files
whose checksums changed are preserved and rejected. Restore the original saved
work, or move the entire version directory aside before preparing afresh. Existing
published versions still require a new `VERSION` for new work. Local `make build`
and `make build-for-this` preserve release directories; `make clean` deletes
`build/`, including the artifacts and recovery records.

See [self-update verification](self-updates.md#verification) for automated
coverage and manual download, installation, and relaunch checks.
