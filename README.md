#  ViewTheWord

MacOS presentation app to display Holy Bible verses in two translations.

## Release and Notarize

One-time setup for notarization credentials:

```bash
xcrun notarytool store-credentials "ViewTheWordNotary" \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "app-specific-password"
```

Create a notarized local release artifact:

```bash
make release-notarize NOTARY_PROFILE=ViewTheWordNotary
```

Create notarized artifacts and publish to GitHub release:

```bash
make release-github \
  NOTARY_PROFILE=ViewTheWordNotary \
  GH_REPO=sukujgrg/ViewTheWord
```

Artifacts are written to `build/release`.
