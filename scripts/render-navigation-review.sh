#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/review/navigation build/NavigationModuleCache
xcrun swiftc -parse-as-library -strict-concurrency=complete -module-cache-path build/NavigationModuleCache \
  ViewTheWord/AppConstants.swift ViewTheWord/RxVerse.swift ViewTheWord/Db.swift ViewTheWord/Core/*.swift \
  ViewTheWord/NativeReferenceTable.swift ViewTheWord/NativeSearchField.swift ViewTheWord/AppKit/*.swift \
  ViewTheWord/HelpView.swift ViewTheWord/Extensions.swift ViewTheWord/ProjectorView.swift ViewTheWord/SettingsView.swift \
  scripts/render-navigation-review.swift -o build/review/navigation/check-navigation
build/review/navigation/check-navigation
