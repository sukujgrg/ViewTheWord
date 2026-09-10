#!/bin/bash

set -euo pipefail

BUILD_CURRENT_ARCH_ONLY=false

usage() {
  cat <<'EOF'
Usage: ./scripts/build.sh [--current-arch] [--help]

Build and export a local app to ~/Applications. Defaults to a universal app.
Use make release to sign, notarize, and publish a distribution release.

Options:
  --current-arch  Build only for the current machine architecture.
  --help          Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --current-arch)
      BUILD_CURRENT_ARCH_ONLY=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "$(dirname "$0")/.."
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ViewTheWord.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE_PATH="$TMP/ViewTheWord.xcarchive"
EXPORT_PLIST="$TMP/ViewTheWord-export.plist"
EXPORT_PATH="$HOME/Applications"

mkdir -p "$EXPORT_PATH"

if [[ "$BUILD_CURRENT_ARCH_ONLY" == true ]]; then
  BUILD_ARGS=(ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES)
else
  BUILD_ARGS=("ARCHS=arm64 x86_64" ONLY_ACTIVE_ARCH=NO)
fi

xcodebuild \
  -project ViewTheWord.xcodeproj \
  -scheme ViewTheWord \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  STRIP_INSTALLED_PRODUCT=YES \
  COPY_PHASE_STRIP=YES \
  "${BUILD_ARGS[@]}"

cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>mac-application</string>
  <key>signingStyle</key><string>manual</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
  <key>signingCertificate</key><string></string>
  <key>provisioningProfiles</key><dict/>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST"
