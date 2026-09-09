#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/review/rendered build/ModuleCache
xcrun swiftc -parse-as-library -module-cache-path build/ModuleCache \
  ViewTheWord/AppConstants.swift ViewTheWord/RxVerse.swift ViewTheWord/Db.swift \
  ViewTheWord/Core/*.swift ViewTheWord/ProjectorView.swift scripts/render-projector-review.swift \
  -o build/review/rendered/render-projector
build/review/rendered/render-projector
