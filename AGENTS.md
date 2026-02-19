# ViewTheWord - Agent Guide (Current)

## ViewTheWord Working Memory (2026-02-19)

This document is the current source of truth for this repo.

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
- `projectorViewModel.projectorViewData` is the projected content state.
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
- Use `.onExitCommand(perform:)` for Escape behavior instead of invisible buttons.
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
- Projector window lifecycle logic exists in both `MainView` and `VerseRowView`; if that area is touched again, prefer consolidating into one coordinator API.
