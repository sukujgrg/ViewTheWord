#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/review/navigation build/NavigationModuleCache
xcrun swiftc -parse-as-library -D VTW_REVIEW -strict-concurrency=complete -module-cache-path build/NavigationModuleCache \
  ViewTheWord/AppConstants.swift ViewTheWord/RxVerse.swift ViewTheWord/Db.swift ViewTheWord/Core/*.swift \
  ViewTheWord/NativeReferenceTable.swift ViewTheWord/NativeSearchField.swift ViewTheWord/AppKit/*.swift \
  ViewTheWord/HelpView.swift ViewTheWord/Extensions.swift ViewTheWord/ProjectorView.swift ViewTheWord/SettingsView.swift \
  scripts/render-navigation-review.swift -o build/review/navigation/check-navigation
# LaunchServices activation is reliable for an application bundle; a raw command-
# line executable can be refused activation by macOS, leaving no real key window.
REVIEW_OUTPUT="$PWD/build/review/navigation"
REVIEW_APP="$REVIEW_OUTPUT/NativeWorkspaceReview.app"
mkdir -p "$REVIEW_APP/Contents/MacOS"
cp "$REVIEW_OUTPUT/check-navigation" "$REVIEW_APP/Contents/MacOS/check-navigation.new"
mv -f "$REVIEW_APP/Contents/MacOS/check-navigation.new" "$REVIEW_APP/Contents/MacOS/check-navigation"
cat > "$REVIEW_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.viewtheword.NativeWorkspaceReview</string>
<key>CFBundleName</key><string>Native Workspace Review</string>
<key>CFBundleExecutable</key><string>check-navigation</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$REVIEW_APP"
rm -f "$REVIEW_OUTPUT/passed"
: > "$REVIEW_OUTPUT/events.log"
: > "$REVIEW_OUTPUT/events-errors.log"
open -n -W --stdout "$REVIEW_OUTPUT/events.log" --stderr "$REVIEW_OUTPUT/events-errors.log" "$REVIEW_APP" --args "$PWD"
cat "$REVIEW_OUTPUT/events.log" "$REVIEW_OUTPUT/events-errors.log"
# open reports launch success rather than the app's exit code. Only a completed
# review writes this marker; assertions, crashes, and thrown errors fail the script.
test -f "$REVIEW_OUTPUT/passed"
