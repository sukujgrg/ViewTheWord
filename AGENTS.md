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
  - Bookmark/History row activation is explicit and consistent:
    - rows use explicit `Button` activation for mouse clicks (single click always navigates)
    - `List(selection:)` remains for keyboard navigation
    - tap-activation dedupe state (`bookmarkTapActivatedID`, `historyTapActivatedID`) prevents double-dispatch when selection `onChange` also fires
- Semantic/AI search has been removed:
  - No embeddings/OpenAI pipeline remains in runtime, parser, or settings.
  - Search supports verse lookup and SQLite-backed text search (`s:` phrase / `m:` multi-term) only.
- Verse POST API feature has been removed:
  - `ApiCalls.swift` and all network-post hooks are deleted.
  - Projection is local-only; do not reintroduce network side effects from `ProjectorView` (`onChange`/`onDisappear`).
- Display slider behavior is stabilized:
  - Keep font/padding sliders draft-backed and commit to `@AppStorage` on edit end.
  - Avoid wrapping slider groups in a parent `ScrollView` to prevent drag gesture contention.
  - Keep numeric `@AppStorage` types consistent across views (for font sizes use `Double` end-to-end).
- Known translation verse-number divergence (important for row/projection boundaries):
  - `ENG_NIV.bible` vs `ENG_NLT.bible` differ in New Testament chapter verse numbering.
  - `3 John 1`: NIV has 14 verses; NLT has 15 (NLT-only verse number `15`).
  - `Revelation 12`: NIV has 17 verses; NLT has 18 (NLT-only verse number `18`).
  - Do not assume `row index + 1 == verse number` in dual-translation mode.

### Current app structure (actual code)
- Entry: `ViewTheWord/ViewTheWordApp.swift`
- Main orchestration: `ViewTheWord/ContentView.swift` (`MainView`)
- Verse list + keyboard navigation + projector trigger: `ViewTheWord/VerseRowView.swift`
- Projected output view: `ViewTheWord/ProjectorView.swift`
- Search parsing: `ViewTheWord/RxVerse.swift`
- Bible DB access: `ViewTheWord/Db.swift`
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
- Chapter selection must not round-trip through text parsing:
  - chapter click should navigate directly via `VerseReference(book, chapter, verse: 1)`
  - avoid parser involvement in this flow to prevent stale/ambiguous selection state
- Avoid `Task.detached` for UI-owned workflows unless isolation boundaries are explicit and required.

### SwiftUI safety lessons
- Avoid hidden controls for keyboard shortcuts.
- For projector ESC behavior on borderless macOS windows, prefer native AppKit responder handling (window-level `cancelOperation` / `keyDown`) over hidden controls.
- Avoid `DispatchQueue.main.async` as a generic fix for publish-during-update warnings.
- For verse auto-scroll, defer one render pass with `Task.yield()` and scroll intentionally.
- Break complex `body` expressions into small subviews when type-checking slows down (e.g., `SearchResultRowView`).
- `List(selection:)` `onChange` does not fire when clicking an already selected row; for deterministic activation, use explicit row `Button` handlers and keep selection `onChange` for keyboard paths.
- Do not place continuously dragged `Slider` controls inside `List` rows for this app's settings screen; prefer `VStack`/`GroupBox` layout with draft state + commit-on-edit-end to avoid sticky drag and heavy re-layout.

### Styling/HIG lessons
- Never hardcode blue for selection/highlight.
- Use accent-aware styling (`.accentColor` / `.foregroundColor(.accentColor)`).

### Database/concurrency constraints
- `Bible` is queue-confined and marked `@unchecked Sendable`.
- If touched, preserve queue confinement rules:
  - all SQLite access on their private queues
  - no shared mutable state read/write from outside queue boundaries

### Settings and persistence gotchas
- Bible picker values must be tagged with `absoluteString` to match `AppStorage` string bindings.
- Bible defaults keys are centralized in `AppDefaultsKey` (`primaryBibleName`, `secondaryBibleName`, `showOnlyPrimary`); avoid raw string keys.
- Keep numeric `@AppStorage` type usage consistent across all readers/writers (avoid `Int` in one view and `Double` in another for the same key).
- Bible filename validation is centralized in `BibleFileRule` and must stay consistent between import flow and discovery (`BibleUrl.getAvailableBibleUrls()`).
- Bible import is actor-backed (`BibleImportService`) and performs strict checks before copy:
  - canonical filename
  - SQLite header
  - required `bible` table columns (`bnumber`, `cnumber`, `vnumber`, `verse`)
  - `bnames` table presence with canonical book-count row cardinality
  - canonical `bnumber` coverage (`1...66`) and canonical chapter coverage per book
- Import copy is atomic (temp file + move). Permission hardening (`0444`) is best-effort and should not fail an otherwise valid import.

### Logging
- Use native Apple logging (`Logger` / unified logging) for app events.
- Avoid logging sensitive content (including verse API endpoints with secrets or credential material).

### Build and validation
- Preferred build command:
  - `xcodebuild -project ViewTheWord.xcodeproj -scheme ViewTheWord -configuration Debug -derivedDataPath build/DerivedData build`
- In sandboxed environments, unrestricted build may be required because Xcode/SwiftPM cache paths are outside workspace.

### Remaining architectural debt to watch
- Keep projector lifecycle ownership in `MainView`; do not reintroduce direct projector window/state mutation in `VerseRowView`.
