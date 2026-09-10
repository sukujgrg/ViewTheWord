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
It then builds the universal app, signs with Developer ID, notarizes and staples
it, and generates the signed Sparkle feed. Only when the artifacts are ready
does it create and push `v<VERSION>` and publish the GitHub release. Existing
tags must point to the same commit; existing releases are never overwritten.
Publication uploads the zip, checksum, source metadata, and `appcast.xml`, and
marks the release as latest.

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
```

A different local notary profile can be selected with `NOTARY_PROFILE=ProfileName`.
Version, tag, build-number, and repository overrides are removed; there is no
validation bypass.

## Artifacts and retries

Artifacts are saved under `build/release/v<VERSION>/`: the app, notarized zip,
checksum, source metadata, and signed `appcast.xml`. Local `make build` and
`make build-for-this` commands preserve these artifacts; `make clean` deletes
`build/`, including saved release artifacts.

If publication fails, the local artifacts remain available. A retry rechecks CI
and the destination; an existing matching tag can be reused, but a published
release requires a new version. Source edits, failed CI, or a changed latest
release stop publication. The command never force-pushes a tag.

See [self-update verification](self-updates.md#verification) for automated
coverage and manual download, installation, and relaunch checks.
