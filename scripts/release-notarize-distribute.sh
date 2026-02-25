#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release-notarize-distribute.sh --notary-profile PROFILE [options]

Required:
  --notary-profile PROFILE   notarytool keychain profile name.

Optional:
  --project PATH             Xcode project path (default: ViewTheWord.xcodeproj)
  --scheme NAME              Xcode scheme (default: ViewTheWord)
  --configuration NAME       Build configuration (default: Release)
  --version VERSION          Release version (default: contents of VERSION file)
  --output-dir DIR           Output directory (default: build/release)
  --team-id TEAM_ID          Apple Developer Team ID for export signing.
  --signing-identity NAME    Override CODE_SIGN_IDENTITY at archive time.
  --current-arch             Build only current machine architecture.
  --allow-provisioning       Pass -allowProvisioningUpdates to xcodebuild.

GitHub distribution:
  --github                   Upload artifacts to GitHub release using gh CLI.
  --repo OWNER/REPO          GitHub repository slug. Required when --github is set.
  --tag TAG                  Git tag for the release (default: v<VERSION>)
  --notes FILE               Release notes file path for gh release create.

Examples:
  ./scripts/release-notarize-distribute.sh --notary-profile ViewTheWordNotary

  ./scripts/release-notarize-distribute.sh \
    --notary-profile ViewTheWordNotary \
    --github \
    --repo sukujgrg/ViewTheWord \
    --tag v3.0.1

One-time notary profile setup example:
  xcrun notarytool store-credentials "ViewTheWordNotary" \
    --apple-id "you@example.com" \
    --team-id "TEAMID1234" \
    --password "app-specific-password"
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

PROJECT="ViewTheWord.xcodeproj"
SCHEME="ViewTheWord"
CONFIGURATION="Release"
OUTPUT_DIR="build/release"
NOTARY_PROFILE=""
TEAM_ID=""
SIGNING_IDENTITY=""
VERSION=""
CURRENT_ARCH_ONLY=false
ALLOW_PROVISIONING=false
PUBLISH_GITHUB=false
REPO=""
TAG=""
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT="$2"
      shift 2
      ;;
    --scheme)
      SCHEME="$2"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --team-id)
      TEAM_ID="$2"
      shift 2
      ;;
    --signing-identity)
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --current-arch)
      CURRENT_ARCH_ONLY=true
      shift
      ;;
    --allow-provisioning)
      ALLOW_PROVISIONING=true
      shift
      ;;
    --github)
      PUBLISH_GITHUB=true
      shift
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --notes)
      NOTES_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

derive_repo_from_origin() {
  local origin_url
  origin_url="$(git config --get remote.origin.url 2>/dev/null || true)"
  [[ -n "$origin_url" ]] || return 1

  local repo_slug=""

  if [[ "$origin_url" =~ ^https://github.com/([^/]+/[^/.]+)(\.git)?$ ]]; then
    repo_slug="${BASH_REMATCH[1]}"
  elif [[ "$origin_url" =~ ^git@github.com:([^/]+/[^/.]+)(\.git)?$ ]]; then
    repo_slug="${BASH_REMATCH[1]}"
  fi

  [[ -n "$repo_slug" ]] || return 1
  printf '%s' "$repo_slug"
}

if [[ -z "$NOTARY_PROFILE" ]]; then
  fail "--notary-profile is required"
fi

if [[ -z "$VERSION" ]]; then
  if [[ -f VERSION ]]; then
    VERSION="$(tr -d '[:space:]' < VERSION)"
  fi
  [[ -n "$VERSION" ]] || fail "Unable to determine version. Pass --version or create VERSION file."
fi

if [[ "$PUBLISH_GITHUB" == true ]]; then
  if [[ -z "$REPO" ]]; then
    REPO="$(derive_repo_from_origin || true)"
  fi
  [[ -n "$REPO" ]] || fail "--repo OWNER/REPO is required when --github is set (or set a GitHub origin remote)"
  [[ -n "$TAG" ]] || TAG="v$VERSION"
fi

require_command xcodebuild
require_command xcrun
require_command ditto
require_command shasum

if [[ "$PUBLISH_GITHUB" == true ]]; then
  require_command gh
fi

TMP_DIR="$(mktemp -d "${TMPDIR%/}/ViewTheWordRelease.XXXXXX")"
ARCHIVE_PATH="$TMP_DIR/$SCHEME.xcarchive"
EXPORT_PATH="$TMP_DIR/export"
EXPORT_PLIST="$TMP_DIR/exportOptions.plist"
NOTARY_JSON="$TMP_DIR/notary-result.json"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR" "$EXPORT_PATH"

{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0">'
  echo '<dict>'
  echo '  <key>method</key><string>developer-id</string>'
  echo '  <key>signingStyle</key><string>automatic</string>'
  echo '  <key>stripSwiftSymbols</key><true/>'
  echo '  <key>compileBitcode</key><false/>'
  if [[ -n "$TEAM_ID" ]]; then
    echo "  <key>teamID</key><string>$TEAM_ID</string>"
  fi
  echo '</dict>'
  echo '</plist>'
} > "$EXPORT_PLIST"

BUILD_ARGS=()

if [[ "$CURRENT_ARCH_ONLY" == true ]]; then
  CURRENT_ARCH="$(uname -m)"
  BUILD_ARGS+=(
    "ARCHS=$CURRENT_ARCH"
    "ONLY_ACTIVE_ARCH=YES"
  )
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  BUILD_ARGS+=("CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")
fi

ARCHIVE_CMD=(
  xcodebuild
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -archivePath "$ARCHIVE_PATH"
  archive
  SKIP_INSTALL=NO
  STRIP_INSTALLED_PRODUCT=YES
  COPY_PHASE_STRIP=YES
)

if [[ "$ALLOW_PROVISIONING" == true ]]; then
  ARCHIVE_CMD+=(-allowProvisioningUpdates)
fi

if ((${#BUILD_ARGS[@]} > 0)); then
  ARCHIVE_CMD+=("${BUILD_ARGS[@]}")
fi

echo "==> Archiving ($SCHEME $CONFIGURATION)"
"${ARCHIVE_CMD[@]}"

echo "==> Exporting signed app"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -type d -name "*.app" -print -quit)"
[[ -n "$APP_PATH" ]] || fail "No exported .app found in $EXPORT_PATH"

APP_NAME="$(basename "$APP_PATH" .app)"
NOTARIZE_ZIP="$TMP_DIR/$APP_NAME-$VERSION-notary.zip"
FINAL_ZIP="$OUTPUT_DIR/$APP_NAME-$VERSION-notarized.zip"
FINAL_SHA="$FINAL_ZIP.sha256"
FINAL_APP="$OUTPUT_DIR/$APP_NAME.app"

echo "==> Creating zip for notarization"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "==> Submitting for notarization"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json > "$NOTARY_JSON"

if ! grep -q '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$NOTARY_JSON"; then
  echo "Notarization response:"
  cat "$NOTARY_JSON"
  fail "Notarization did not return Accepted status."
fi

echo "==> Stapling app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Preparing distributable artifacts"
rm -rf "$FINAL_APP"
cp -R "$APP_PATH" "$FINAL_APP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$FINAL_ZIP"
shasum -a 256 "$FINAL_ZIP" > "$FINAL_SHA"

if [[ "$PUBLISH_GITHUB" == true ]]; then
  echo "==> Publishing to GitHub release: $REPO ($TAG)"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$FINAL_ZIP" "$FINAL_SHA" --repo "$REPO" --clobber
  else
    CREATE_ARGS=(
      gh release create "$TAG" "$FINAL_ZIP" "$FINAL_SHA"
      --repo "$REPO"
      --title "$APP_NAME $VERSION"
    )
    if [[ -n "$NOTES_FILE" ]]; then
      CREATE_ARGS+=(--notes-file "$NOTES_FILE")
    else
      CREATE_ARGS+=(--notes "Automated notarized release $VERSION")
    fi
    "${CREATE_ARGS[@]}"
  fi
fi

echo
echo "Release complete."
echo "App: $FINAL_APP"
echo "Zip: $FINAL_ZIP"
echo "SHA: $FINAL_SHA"
