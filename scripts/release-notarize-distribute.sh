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
  --version VERSION          Release version (default: derived from Git tag, else VERSION file)
  --build-number NUMBER      Increasing build number (default: tag +BUILD suffix, else UTC timestamp)
  --skip-version-file-check  Do not require VERSION file to match release version.
  --output-dir DIR           Output directory (default: build/release)
  --team-id TEAM_ID          Apple Developer Team ID for export signing.
  --signing-identity NAME    Override CODE_SIGN_IDENTITY at archive time.
  --current-arch             Local archive only; no self-update feed or GitHub publication.
  --allow-provisioning       Pass -allowProvisioningUpdates to xcodebuild.

GitHub distribution:
  --github                   Upload artifacts to GitHub release using gh CLI.
  --repo OWNER/REPO          GitHub repository slug. Required when --github is set.
  --tag TAG                  Git tag for the release (default: exact tag at HEAD, else v<VERSION>)
  --notes FILE               Release notes file path for gh release create.

Examples:
  ./scripts/release-notarize-distribute.sh --notary-profile ViewTheWordNotary

  ./scripts/release-notarize-distribute.sh \
    --notary-profile ViewTheWordNotary \
    --github \
    --repo sukujgrg/ViewTheWord \
    --tag v3.0.1+45

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
BUILD_NUMBER=""
CURRENT_ARCH_ONLY=false
ALLOW_PROVISIONING=false
PUBLISH_GITHUB=false
REPO=""
TAG=""
NOTES_FILE=""
SKIP_VERSION_FILE_CHECK=false

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
    --build-number)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --skip-version-file-check)
      SKIP_VERSION_FILE_CHECK=true
      shift
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

derive_version_from_tag() {
  local tag="$1"
  local normalized_tag="${tag#refs/tags/}"
  normalized_tag="${normalized_tag#v}"
  local version_part="${normalized_tag%%+*}"

  if [[ "$version_part" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    printf '%s' "$version_part"
    return 0
  fi

  return 1
}

derive_build_from_tag() {
  local tag="$1"
  local normalized_tag="${tag#refs/tags/}"
  normalized_tag="${normalized_tag#v}"

  if [[ "$normalized_tag" =~ \+([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

find_exact_head_tag() {
  command -v git >/dev/null 2>&1 || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git describe --tags --exact-match 2>/dev/null || return 1
}

if [[ -z "$NOTARY_PROFILE" ]]; then
  fail "--notary-profile is required"
fi

TAG="${TAG#refs/tags/}"
if [[ -n "$TAG" ]]; then
  TAG_VERSION="$(derive_version_from_tag "$TAG" || true)"
  [[ -n "$TAG_VERSION" ]] || fail "Tag '$TAG' is not a valid release tag. Use vX.Y.Z or vX.Y.Z+BUILD."

  if [[ -n "$VERSION" && "$VERSION" != "$TAG_VERSION" ]]; then
    fail "--version ($VERSION) does not match --tag ($TAG => $TAG_VERSION)"
  fi
  VERSION="$TAG_VERSION"
fi

if [[ -z "$VERSION" ]]; then
  HEAD_TAG="$(find_exact_head_tag || true)"
  if [[ -n "$HEAD_TAG" ]]; then
    TAG="$HEAD_TAG"
    VERSION="$(derive_version_from_tag "$HEAD_TAG" || true)"
  fi

  if [[ -f VERSION ]]; then
    if [[ -z "$VERSION" ]]; then
      VERSION="$(tr -d '[:space:]' < VERSION)"
    fi
  fi

  [[ -n "$VERSION" ]] || fail "Unable to determine version. Pass --version, create VERSION file, or create a Git tag like vX.Y.Z."
fi

if [[ "$PUBLISH_GITHUB" == true ]]; then
  if [[ -z "$REPO" ]]; then
    REPO="$(derive_repo_from_origin || true)"
  fi
  [[ -n "$REPO" ]] || fail "--repo OWNER/REPO is required when --github is set (or set a GitHub origin remote)"
  [[ -n "$TAG" ]] || TAG="v$VERSION"
fi

if [[ -n "$TAG" ]]; then
  TAG_BUILD="$(derive_build_from_tag "$TAG" || true)"
  if [[ -n "$TAG_BUILD" ]]; then
    [[ -z "$BUILD_NUMBER" || "$BUILD_NUMBER" == "$TAG_BUILD" ]] || fail "--build-number differs from the tag's +BUILD suffix."
    BUILD_NUMBER="$TAG_BUILD"
  fi
fi

# Sparkle compares CFBundleVersion, not the marketing version. The old Xcode
# default (3) was shared by all releases and cannot order self-updates.
[[ -n "$BUILD_NUMBER" ]] || BUILD_NUMBER="$(date -u +%Y%m%d%H%M%S)"

if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  fail "--build-number must be numeric."
fi

if [[ "$SKIP_VERSION_FILE_CHECK" == false ]]; then
  [[ -f VERSION ]] || fail "VERSION file is required for release. Set it to $VERSION."
  VERSION_FILE_VALUE="$(tr -d '[:space:]' < VERSION)"
  [[ -n "$VERSION_FILE_VALUE" ]] || fail "VERSION file is empty. Set it to $VERSION."
  [[ "$VERSION_FILE_VALUE" == "$VERSION" ]] || fail "VERSION file ($VERSION_FILE_VALUE) does not match release version ($VERSION). Update VERSION first."
fi

require_command git
[[ -n "$TAG" ]] || TAG="v$VERSION"
SOURCE_COMMIT="$("$(dirname "$0")/verify-release-source.sh" "$TAG")" || fail "Source verification failed."

require_command xcodebuild
require_command xcrun
require_command ditto
require_command shasum
require_command python3
require_command lipo

if [[ "$PUBLISH_GITHUB" == true && "$CURRENT_ARCH_ONLY" == true ]]; then
  fail "GitHub self-updates must include both Apple silicon and Intel. Remove --current-arch."
fi

[[ -n "$REPO" ]] || REPO="$(derive_repo_from_origin || true)"
[[ -n "$REPO" ]] || fail "Set a GitHub origin or pass --repo for the update feed."

if [[ "$PUBLISH_GITHUB" == true ]]; then
  require_command gh
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Invalid GitHub repository slug."
  REMOTE_TAG_COMMIT="$(gh api "repos/$REPO/commits/tags/$TAG" --jq .sha)" || fail "Release tag must already exist on GitHub."
  [[ "$REMOTE_TAG_COMMIT" == "$SOURCE_COMMIT" ]] || fail "GitHub tag does not match the verified local source."
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    fail "A release already exists for $TAG. Existing release artifacts will not be overwritten."
  fi
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ViewTheWordRelease.XXXXXX")"
ARCHIVE_PATH="$TMP_DIR/$SCHEME.xcarchive"
EXPORT_PATH="$TMP_DIR/export"
EXPORT_PLIST="$TMP_DIR/exportOptions.plist"
NOTARY_JSON="$TMP_DIR/notary-result.json"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR" "$EXPORT_PATH"

SPARKLE_BIN="$ROOT_DIR/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
PREVIOUS_FEED=""
LATEST_TAG=""
if [[ "$CURRENT_ARCH_ONLY" == false ]]; then
  EXPECTED_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' ViewTheWord/Info.plist)"
  [[ "$EXPECTED_FEED_URL" == "https://github.com/$REPO/releases/latest/download/appcast.xml" ]] || fail "The app's update feed does not point to the destination repository."
  xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" -derivedDataPath build/DerivedData
  [[ -x "$SPARKLE_BIN/generate_appcast" ]] || fail "Sparkle signing tools were not resolved."
  # Check the app-specific signing identity before starting the expensive archive.
  UPDATE_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account suku.ViewTheWord -p)" || fail "Set up the update signing key; see docs/self-updates.md."
  EXPECTED_UPDATE_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' ViewTheWord/Info.plist)"
  [[ "$UPDATE_PUBLIC_KEY" == "$EXPECTED_UPDATE_KEY" ]] || fail "The update signing key differs from the public key in Info.plist."
  if [[ "$PUBLISH_GITHUB" == true ]]; then
    ANY_RELEASE="$(gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq '.[0].tagName // empty')"
    if [[ -n "$ANY_RELEASE" ]]; then
      LATEST_TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName)"
      PREVIOUS_FEED_NAME="$(gh release view "$LATEST_TAG" --repo "$REPO" --json assets --jq '.assets[] | select(.name == "appcast.xml") | .name')"
      if [[ -n "$PREVIOUS_FEED_NAME" ]]; then
        mkdir -p "$TMP_DIR/previous"
        gh release download "$LATEST_TAG" --repo "$REPO" --pattern appcast.xml --dir "$TMP_DIR/previous"
        PREVIOUS_FEED="$TMP_DIR/previous/appcast.xml"
      fi
    fi
  fi
fi

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
else
  BUILD_ARGS+=("ARCHS=arm64 x86_64" "ONLY_ACTIVE_ARCH=NO")
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  BUILD_ARGS+=("CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")
fi

BUILD_ARGS+=("MARKETING_VERSION=$VERSION" "VTW_SOURCE_COMMIT=$SOURCE_COMMIT")

if [[ -n "$BUILD_NUMBER" ]]; then
  BUILD_ARGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi

ARCHIVE_CMD=(
  xcodebuild
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath build/DerivedData
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

VERIFIED_COMMIT="$("$(dirname "$0")/verify-release-source.sh" "$TAG")" || fail "Source changed during the archive build."
[[ "$VERIFIED_COMMIT" == "$SOURCE_COMMIT" ]] || fail "Source commit changed during the archive build."

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
FINAL_SOURCE="$FINAL_ZIP.source.txt"
FINAL_FEED="$OUTPUT_DIR/appcast.xml"
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
printf 'source_commit=%s\ntag=%s\nversion=%s\n' "$SOURCE_COMMIT" "$TAG" "$VERSION" > "$FINAL_SOURCE"

if [[ "$CURRENT_ARCH_ONLY" == false ]]; then
  APP_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
  lipo "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE" -verify_arch arm64 x86_64
  FEED_CMD=(python3 scripts/update-feed.py --app "$APP_PATH" --archive "$FINAL_ZIP" --output "$FINAL_FEED"
    --repo "$REPO" --tag "$TAG" --sparkle-bin "$SPARKLE_BIN")
  if [[ -n "$PREVIOUS_FEED" ]]; then FEED_CMD+=(--previous "$PREVIOUS_FEED"); fi
  "${FEED_CMD[@]}"
fi

if [[ "$PUBLISH_GITHUB" == true ]]; then
  echo "==> Publishing to GitHub release: $REPO ($TAG)"
  VERIFIED_COMMIT="$("$(dirname "$0")/verify-release-source.sh" "$TAG")" || fail "Source changed during the release build."
  [[ "$VERIFIED_COMMIT" == "$SOURCE_COMMIT" ]] || fail "Source commit changed during the release build."
  REMOTE_TAG_COMMIT="$(gh api "repos/$REPO/commits/tags/$TAG" --jq .sha)" || fail "Could not recheck the GitHub tag."
  [[ "$REMOTE_TAG_COMMIT" == "$SOURCE_COMMIT" ]] || fail "GitHub tag changed during the release build."
  ANY_RELEASE="$(gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --limit 1 --json tagName --jq '.[0].tagName // empty')"
  CURRENT_LATEST_TAG=""
  if [[ -n "$ANY_RELEASE" ]]; then
    CURRENT_LATEST_TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName)"
  fi
  [[ "$CURRENT_LATEST_TAG" == "$LATEST_TAG" ]] || fail "The latest GitHub release changed during the build. Rebuild with its current update feed."
  CREATE_ARGS=(
    gh release create "$TAG" "$FINAL_ZIP" "$FINAL_SHA" "$FINAL_SOURCE" "$FINAL_FEED"
    --repo "$REPO" --verify-tag --latest --title "$APP_NAME $VERSION"
  )
  if [[ -n "$NOTES_FILE" ]]; then
    CREATE_ARGS+=(--notes-file "$NOTES_FILE")
  else
    CREATE_ARGS+=(--notes "Notarized release $VERSION from source commit $SOURCE_COMMIT")
  fi
  "${CREATE_ARGS[@]}"
fi

echo
echo "Release complete."
echo "App: $FINAL_APP"
echo "Zip: $FINAL_ZIP"
echo "SHA: $FINAL_SHA"
if [[ "$CURRENT_ARCH_ONLY" == false ]]; then echo "Update feed: $FINAL_FEED"; fi
