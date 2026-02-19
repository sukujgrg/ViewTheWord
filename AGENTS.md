# ViewTheWord - Agent Guide (Current)

## ViewTheWord Working Memory (2026-02-19)

This document is the current source of truth for this repo.

### Session handoff note (latest)
- Projection ownership is now explicit and centralized:
  - `MainView` is the only place that sets projected content.
  - `ProjectorViewModel` projection writes go through `project(_:owner:)` and clear through `clearProjection()`.
  - Ownership is typed as `ProjectionOwner` (`textInputTarget`, `verseRowSelection`, `searchResult`).
- `VerseRowView` no longer mutates projector state/window directly:
  - It emits intents only (`onProjectVerse`, `onStopProjection`).
  - Parent (`MainView`) performs project/open/close actions.
- Book/Chapter/Verse boundaries are explicit:
  - `VerseBoundary` and `VerseReference` validate/normalize references.
  - Row projection rejects out-of-range verse indices for current chapter.
- ESC close is now native and reliable for projection:
  - `ProjectorWindow` handles ESC in responder chain (`cancelOperation` / `keyDown`) for borderless window behavior.
- Verse row scrolling behavior is now fixed/default:
  - Removed `scrollTo` setting from Bible settings UI.
  - Verse list always auto-scrolls to the targeted verse (for text-field verse queries like `Psalm 119:53`).
- History flow has explicit boundaries now:
  - Removed history from right-click context menu.
  - History UI is a collapsible section in the chapter column (below chapters).
  - History persistence is file-backed (`HistoryStore`) instead of `@AppStorage([String])`.
  - History capture is source-gated: only direct text-field submit records verse history.

### Current app structure (actual code)
- Entry: `ViewTheWord/ViewTheWordApp.swift`
- Main orchestration: `ViewTheWord/ContentView.swift` (`MainView`)
- Verse list + keyboard navigation + projector trigger: `ViewTheWord/VerseRowView.swift`
- Projected output view: `ViewTheWord/ProjectorView.swift`
- Search parsing: `ViewTheWord/RxVerse.swift`
- Bible DB access: `ViewTheWord/Db.swift`
- Embeddings DB access: `ViewTheWord/EmbeddingsDb.swift`
- Settings/import flows: `ViewTheWord/SettingsView.swift`

### Non-negotiable state ownership
- `verseTargetModel.verseQuery` is the current selected verse source of truth across views.
- projected content ownership is `MainView` + `ProjectorViewModel.project(_:owner:)`; do not directly assign projector payload from child views.
- Keep projector window title centralized: `AppWindowTitle.projector`.
- Keep cross-view notifications centralized in `Notification.Name` extensions (`.focusSearchField`, `.toggleKeyboardShortcuts`).

### Query/search flow lessons
- Do not use bool toggling for validation animation triggers.
- Use monotonic token (`queryValidationToken`) for deterministic invalid-query feedback.
- Do not use “flag + async reset” hacks for sidebar sync.
- Use explicit programmatic guard (`programmaticChapterSelection`) to prevent onChange feedback loops.
- Keep semantic search on structured async path:
  - `EmbeddingsDb.searchBySemanticAsync(...)`
  - `Bible.getVersesAsync(...)`
- Avoid `Task.detached` for UI-owned workflows unless isolation boundaries are explicit and required.

### SwiftUI safety lessons
- Avoid hidden controls for keyboard shortcuts.
- For projector ESC behavior on borderless macOS windows, prefer native AppKit responder handling (window-level `cancelOperation` / `keyDown`) over hidden controls.
- Avoid `DispatchQueue.main.async` as a generic fix for publish-during-update warnings.
- For verse auto-scroll, defer one render pass with `Task.yield()` and scroll intentionally.
- Break complex `body` expressions into small subviews when type-checking slows down (e.g., `SearchResultRowView`).

### Styling/HIG lessons
- Never hardcode blue for selection/highlight.
- Use accent-aware styling (`.accentColor` / `.foregroundColor(.accentColor)`).

### Database/concurrency constraints
- `Bible` and `EmbeddingsDb` are queue-confined classes and marked `@unchecked Sendable`.
- If touched, preserve queue confinement rules:
  - all SQLite access on their private queues
  - no shared mutable state read/write from outside queue boundaries

### Settings and persistence gotchas
- API post URL is stored as `String` in `@AppStorage(AppDefaultsKey.apiUrlToPost)`.
- Keep URL validation explicit (only `http`/`https` with host).
- Migrate legacy `URL`-typed stored value in `onAppear` if present.
- Bible picker values must be tagged with `absoluteString` to match `AppStorage` string bindings.

### Logging and sensitive data
- `FileLogger` uses one `ISO8601DateFormatter` instance; avoid per-log allocations.
- `clearLog()` should truncate current file handle, not rewrite path while handle stays open.
- Do not log secret lengths or key material during Keychain operations.

### Build and validation
- Preferred build command:
  - `xcodebuild -project ViewTheWord.xcodeproj -scheme ViewTheWord -configuration Debug -derivedDataPath build/DerivedData build`
- In sandboxed environments, unrestricted build may be required because Xcode/SwiftPM cache paths are outside workspace.

### Remaining architectural debt to watch
- Keep projector lifecycle ownership in `MainView`; do not reintroduce direct projector window/state mutation in `VerseRowView`.
