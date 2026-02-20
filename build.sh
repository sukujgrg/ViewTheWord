#!/bin/bash

set -euo pipefail

TMP="$(mktemp -d "${TMPDIR%/}/ViewTheWord.XXXXXX")"
ARCHIVE_PATH="$TMP/ViewTheWord.xcarchive"
EXPORT_PLIST="$TMP/ViewTheWord-export.plist"
EXPORT_PATH="$HOME/Applications"

mkdir -p "$EXPORT_PATH"

xcodebuild \
  -project ViewTheWord.xcodeproj \
  -scheme ViewTheWord \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  STRIP_INSTALLED_PRODUCT=YES \
  COPY_PHASE_STRIP=YES


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
