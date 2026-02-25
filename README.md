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
echo "3.1.0" > VERSION
git tag v3.1.0
make release-notarize NOTARY_PROFILE=ViewTheWordNotary TAG=v3.1.0
```

Create notarized artifacts and publish to GitHub release:

```bash
make release-github \
  NOTARY_PROFILE=ViewTheWordNotary \
  GH_REPO=sukujgrg/ViewTheWord \
  TAG=v3.1.0
```

Artifacts are written to `build/release`.

Release guardrails:

- Script derives app `MARKETING_VERSION` from `TAG` (or exact HEAD tag, then `VERSION` file fallback).
- `VERSION` file must match the resolved release version; release fails if it is not updated.
- Optional tag format `vX.Y.Z+BUILD` also sets `CURRENT_PROJECT_VERSION=BUILD`.
