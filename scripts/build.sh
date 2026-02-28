#!/bin/bash

set -euo pipefail

BUILD_CURRENT_ARCH_ONLY=false

usage() {
  cat <<'EOF'
Usage: ./build.sh [--current-arch] [--help]

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

TMP="$(mktemp -d "${TMPDIR%/}/ViewTheWord.XXXXXX")"
ARCHIVE_PATH="$TMP/ViewTheWord.xcarchive"
EXPORT_PLIST="$TMP/ViewTheWord-export.plist"
EXPORT_PATH="$HOME/Applications"

mkdir -p "$EXPORT_PATH"

CURRENT_ARCH="$(uname -m)"
BUILD_ARGS=()

if [[ "$BUILD_CURRENT_ARCH_ONLY" == true ]]; then
  BUILD_ARGS+=(
    ARCHS="$CURRENT_ARCH"
    ONLY_ACTIVE_ARCH=YES
  )
fi

ARCHIVE_CMD=(
  xcodebuild
  -project ViewTheWord.xcodeproj
  -scheme ViewTheWord
  -configuration Release
  -archivePath "$ARCHIVE_PATH"
  archive
  STRIP_INSTALLED_PRODUCT=YES
  COPY_PHASE_STRIP=YES
)

if ((${#BUILD_ARGS[@]} > 0)); then
  ARCHIVE_CMD+=("${BUILD_ARGS[@]}")
fi

"${ARCHIVE_CMD[@]}"


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
