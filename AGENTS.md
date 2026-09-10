# ViewTheWord - Agent Guide (Current)

## ViewTheWord Working Memory (2026-09-09)

This document is the current source of truth for this repo.

### Review implementation (2026-09-07)
- `Core/VerseTargetModel.swift` owns lazy database readers, cancellable navigation/search work, and projection preparation through `BibleReading`. It never opens a window or publishes live content.
- `verseTargetModel.verseQuery` is computed from one published navigation snapshot containing the selected reference, complete chapter rows, and `BibleSources`. Verse rows emit full `VerseReference` intents; Option-Up/Down delegates chapter loading to MainWorkspaceController.
- Browsing/search and live projection refresh are independent. Only a newer projection intent or close invalidates projection work; canceling a verse submission also cancels its own pending projection. `LiveProjectionController` is the shared sole publisher and lifecycle owner across all passage tabs. Keep the deferred close cleanup and its revision/window-identity guard.
- Text searches merge by coordinates across both translations, fetch counterpart text, and use cursor pagination (100 results plus a lookahead). SQL selects four named columns; imported `id` and column order are irrelevant. Words use Unicode boundaries and NOT > AND > OR, with implicit AND and strict syntax errors.
- `Core/BibleLibrary.swift` provides one shared observable import/translation library. Imports snapshot committed SQLite/WAL data, normalize to standalone journal mode, validate coordinates and canonical coverage, create a unique coordinate index, and atomically install. Replacement is explicit; removal uses Trash.
- `Core/Persistence.swift` contains history/bookmark stores, recovery copies for unreadable data, visible errors, and undoable bookmark clearing. Defaults and projector types live in AppConstants/Core.
- Preserve preferred display IDs when disconnected. LiveProjectionController owns the single projector window reference. Blank hides the content; preview uses display proportions. Text fitting uses AppKit measurement followed by SwiftUI natural-height checks; do not reintroduce a fixed ten-line cap.
- Xcode's ordinary version comes from `Config/Version.xcconfig`, generated with `scripts/set-version.sh` from VERSION. Release preflight requires a clean tree and matching tag/HEAD; publication additionally verifies GitHub's tag and refuses to overwrite a release.
- Regression commands: `swift test --scratch-path build/SwiftPM` and `python3 scripts/test-review-regressions.py`. Offscreen projector checks: `scripts/render-projector-review.sh`. See `docs/architecture.md` for state ownership and automated coverage, and `docs/manual-validation.md` for manual checks.

### Session handoff note (latest)
- Asynchronous search/navigation completion may focus results only while the submitting draft, search editing session, and first responder are unchanged. AppKit's Return end-editing notification belongs to the submission itself; later edits or focus changes invalidate that focus request.
- Search pagination inserts appended rows without reloading existing row heights and preserves the visible reference plus offset. New searches and explicit verse reveals still scroll to the selection.
- Library imports queue every incoming URL, retaining security-scoped access through replacement decisions. Import alerts queue per presenter; passage tabs atomically claim alerts and complete them by ID after dismissal. Canceling or failing a replacement resumes the remaining files.
- Translation/catalog refreshes preserve each tab's browsed book and testament filter. Only explicit book/reference navigation reveals a testament. Valid row projection and projection retries clear obsolete navigation errors.
- The app requires macOS 26.0 or later in both the Xcode project and Swift package. CI uses `macos-26` with Xcode 26.5 selected through `DEVELOPER_DIR`; keep the toolchain explicit.
- Self-updates use Sparkle 2.9.6, pinned in the Xcode project. `AppDelegate` owns one `AppUpdateController`, shared across passage toolbars; `SparkleUpdateDriver` owns Sparkle's native UI and installer. Scheduled checks only show an Update button; installation/restart requires user action. Preserve App Sandbox, installer/downloader XPC flags, Mach lookup entitlements, and signed-feed enforcement. The existing update signing key is in the maintainer's Keychain under account `suku.ViewTheWord`; only its public key belongs in Info.plist. Release archives are universal and publish a signed `appcast.xml` with increasing build numbers. SwiftPM and the navigation harness use injected/offline update controls. See `docs/self-updates.md`.
- Passage tabs use native `NSWindow` tabbing, retained by `PassageTabsController`. Each tab keeps its full AppKit hierarchy, navigation model, query mode/draft/results/selection, and scroll positions. Native tab groups handle selection, dragging/reordering, detach, and merge.
- Command-T creates a tab; Command-Return and row context menus open the selected passage in a new tab without projection or history capture. Command-W closes a tab, Control-Tab/Control-Shift-Tab and Command-Shift-[/] switch tabs. Closing/switching tabs never stops already-published live output, even when the originating or last tab closes.
- Bookmarks, bookmark Undo, History, translations/preferences, and live projection are shared. Every tab observes the same Live/Blank state. Preview is local to a tab and observes shared output. Only the active tab may request focus or present library alerts; a replacement prompt claims the shared pending request before presenting.
- Shared projection intents invalidate pending preparation across tabs, while each `VerseTargetModel` still cancels its own superseded verse submission. Translation refresh uses a separate shared reader so browsing or closing the originating tab cannot cancel it. Deferred close retains revision/window guards and preserves newer pending preparation while clearing stopped output.
- The main workspace is entirely AppKit. `ViewTheWordApp` starts `NSApplication`; `PassageTabsController` retains the passage windows; each `MainWindowController` owns one native window/tab and `MainWorkspaceController` owns its navigation orchestration. One `LiveProjectionController` owns shared live projection. Settings, help, preview, and projected content remain isolated SwiftUI screens.
- `AppKit/NativeSidebar.swift` provides native book, bookmark, and history rows. Bookmarks and History have separate, resizable panes. Same-row mouse activation remains explicit.
- Books use a pinned native Old Testament / New Testament segmented control above a flat book list. The filter is local to each passage tab and changes only the visible books. Explicit book/reference navigation reveals its testament; unrelated snapshots preserve the filter and focus. Keep the control outside the scroll view and size the sidebar minimum to fit both full titles.
- `AppKit/ChapterGridController.swift` provides an adaptive `NSCollectionView` of chapter-number buttons. Column count follows available width, with no fixed three-column layout. Arrow keys use native spatial navigation; Command-Left/Right changes workspace columns.
- Keyboard entry after browsing a new book starts with no chapter selected. The first unmodified arrow, Return, or Space activates chapter 1; subsequent arrows use AppKit spatial navigation. Tab itself only changes focus. `ReferenceNSTableView` must pass Tab/Shift-Tab to `super.keyDown`, since sending them through `interpretKeyEvents` traps focus. The event harness checks book → Tab → usable chapter navigation, not just first-responder identity.
- `NativeReferenceTable.swift` provides native verse and search-result tables. `NativeSearchField.swift` supplies the real `NSSearchToolbarItem` field. There are no SwiftUI representables or focus bindings in the workspace.
- Applying snapshots is silent. Native controls own focus; model updates never request first responder. Explicit navigation commands may request focus when their navigation completes. Keep complete `VerseReference` identities and direct chapter navigation without parsing.
- Vertical pane stacks use explicit cross-axis width constraints. `NSStackView.alignment = .width` is invalid and can leave saved-reference content floating within a resized pane. `WorkspaceColumnStack` restores its width constraints when hidden rows reattach.
- Native table rows use automatic heights from constrained `NSTextField`s. Do not query/reconfigure row views inside selection delegates. Coalesce resize-driven height invalidation after `Task.yield()` and disable implicit height animation.
- A new chapter-data UUID reveals a resubmitted verse; bookmark-only refreshes preserve scroll. Grid reveal runs after collection layout, uses `.nearestHorizontalEdge` for vertical scrolling, and preserves a visible selected chapter when column count changes.
- Verse reveals wait for pending width-driven height invalidation and AppKit's automatic row measurements, including newly exposed neighbors. Center a verse that fits, align the start of an oversized verse to the top, and cancel superseded reveals. `scripts/render-navigation-review.sh --history-reveal-only` checks Psalm 117:2 → History Esther 8:9 at normal/compact sizes and with Primary Only.
- User scrolling and row navigation cancel pending verse reveals. Observe both `willStartLiveScroll` and `didLiveScroll` on the local scroll view so legacy mouse wheels are covered. Scroll tests wait for `isRevealingSelection` to finish before moving the viewport; a fixed delay or already-visible row does not establish reveal completion.
- Ordinary verse selection projects; search-result arrow selection does not project until Return/Space or a click. Space compares the actual projected reference. Book and chapter browsing do not project. Activating a bookmark or history entry loads, selects, and projects that reference in one action, including same-row reactivation. Replaying saved references does not capture history.
- Native tab checks launch a fixture app through LaunchServices and inject its BibleLibrary catalog, avoiding macOS activation races and unrelated Documents discovery. The app still runs a real event loop; projector windows are suppressed. Test viewport restoration by visible verse and offset because automatic row measurements can change absolute scroll coordinates.
- First-click validation now runs in `scripts/render-navigation-review.sh` with a real `NSApplication.run()` loop and key `NSWindow`. It dispatches book-to-chapter clicks through `window.sendEvent`, checks four books, spatial grid arrows, toolbar command routing, adaptive widths, and bilingual rendering. The old mocked-key-window/direct-table-mouse regression was removed.
- Physical OS-delivered clicks, VoiceOver, and external-display checks still require the manual checks in `docs/manual-validation.md`. Computer-use permissions were unavailable during this migration; do not describe window-dispatched synthetic events as physical clicks. Native macOS glass is not fully captured by offscreen view caching.
- See `docs/architecture.md` for the current workspace architecture and validation boundaries.
- Projection ownership is now explicit and centralized:
  - `LiveProjectionController` is the only place that sets projected content. Passage workspaces submit globally ordered intents before asynchronous preparation begins.
  - `ProjectorViewModel` projection writes go through `project(_:owner:)` and clear through `clearProjection()`.
  - Ownership is typed as `ProjectionOwner` (`textInputTarget`, `verseRowSelection`, `searchResult`).
- Workspace controls emit navigation/projection intents to the root controller. Do not publish projection from a row, sidebar, grid item, or settings screen.
- Book/Chapter/Verse boundaries are explicit:
  - `VerseBoundary` and `VerseReference` validate/normalize references.
  - Row projection rejects references that are absent from the current chapter.
- ESC close for projection uses a dual-path deferred flow:
  - **Main window key (normal case):** ESC → native responder close intent → `MainWorkspaceController.closeProjector()` → shared `LiveProjectionController.closeProjector()` → `window.close()` → `willCloseNotification` → deferred state cleanup.
  - **Projector window key (rare):** ESC → `ProjectorWindow.cancelOperation` → deferred `DispatchQueue.main.async` posts `.closeProjectorRequested` notification → `LiveProjectionController` receives → `closeProjector()` → same path.
  - State cleanup (`clearProjection`, `windowOpened = false`) is always deferred via `DispatchQueue.main.async` in `handleProjectorWindowClosed()` to avoid re-entrant SwiftUI/AppKit constraint updates during window teardown.
  - `ProjectorView` has no `onDisappear` teardown and no `@Binding windowOpened` — all projector lifecycle is owned by `LiveProjectionController`.
  - Do not use `performClose(nil)` on the projector window — it silently fails on borderless windows (no visible close button). Use `close()` instead.
  - Do not call `close()` directly from `ProjectorWindow.keyDown`/`cancelOperation` — this causes AppKit/SwiftUI constraint crashes during event handling. Always defer to next runloop tick.
- HDMI/screen-change projection hardening (learned from `eucaly` patterns):
  - Do not reposition projector window synchronously on every `didChangeScreenParametersNotification`.
  - Use a coalesced/deferred path (`scheduleProjectorWindowReposition`) with a cancellable `Task` and short delay to avoid rapid `setFrame` churn during display attach/detach.
  - Cancel pending reposition tasks on projector close and application shutdown. Closing a passage tab must not cancel shared output or display repositioning.
  - Prefer `NSView` container + constraints hosting pattern for projector content instead of assigning `NSHostingView` directly as `window.contentView`.
  - Keep projector `collectionBehavior` set to `[.canJoinAllSpaces, .fullScreenAuxiliary]` for stable external-display/full-screen behavior.
- Verse row scrolling behavior is now fixed/default:
  - Removed `scrollTo` setting from Bible settings UI.
  - Verse list always auto-scrolls to the targeted verse (for text-field verse queries like `Psalm 119:53`).
- History flow has explicit boundaries now:
  - Removed history from right-click context menu.
  - History has its own resizable native pane below the chapter grid and bookmarks.
  - History persistence is file-backed (`HistoryStore`) instead of `@AppStorage([String])`.
  - History capture is source-gated: only direct text-field submit records verse history.
  - Bookmark/History row selection handles keyboard navigation; explicit same-row mouse activation handles returning to the selected reference.
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
- Main window and commands: `ViewTheWord/AppKit/MainWindowController.swift`
- Per-tab navigation: `ViewTheWord/AppKit/MainWorkspaceController.swift`
- Tab retention and shared services: `PassageTabsController` in `ViewTheWord/AppKit/MainWindowController.swift`
- Native layout, toolbar, and options: `ViewTheWord/AppKit/WorkspaceInterface.swift`, `WorkspaceOptions.swift`
- Native chapter grid: `ViewTheWord/AppKit/ChapterGridController.swift`
- Book, bookmark, and history rows: `ViewTheWord/AppKit/NativeSidebar.swift`
- Verse/results rows: `ViewTheWord/NativeReferenceTable.swift`
- Projector lifecycle and preview: `ViewTheWord/AppKit/WorkspaceProjection.swift`
- Native query editing, recents, and search commands: `ViewTheWord/NativeSearchField.swift`
- Projected output view: `ViewTheWord/ProjectorView.swift`
- Search parsing: `ViewTheWord/RxVerse.swift`
- Bible DB access: `ViewTheWord/Db.swift`
- Settings/import flows: `ViewTheWord/SettingsView.swift`

### Non-negotiable state ownership
- `verseTargetModel.verseQuery` is the current selected verse source of truth across views.
- projected content ownership is shared `LiveProjectionController` + `ProjectorViewModel.project(_:owner:)`; do not directly assign projector payload from child views.
- Keep projector window title centralized: `AppWindowTitle.projector`.
- Keep cross-view notifications centralized in `Notification.Name` extensions (`.focusSearchField`, `.toggleKeyboardShortcuts`, `.closeProjectorRequested`).

### Query/search flow lessons
- Verse rows and scrolling anchors must use complete verse coordinates as identity. Positional `.id(index)` can leave stale row content and highlights after changing chapters or books.
- Verse and current-chapter highlights follow the selected navigation reference, independently of projection and keyboard focus. Space checks the projected reference when deciding whether to stop or project.
- Do not use bool toggling for validation animation triggers.
- Use monotonic token (`queryValidationToken`) for deterministic invalid-query feedback.
- Do not use “flag + async reset” hacks for sidebar sync.
- Use the native controllers' snapshot guards to prevent programmatic selection feedback loops. Do not restore chapter selection `onChange` navigation in SwiftUI.
- Chapter selection must not round-trip through text parsing:
  - chapter click should navigate directly via `VerseReference(book, chapter, verse: 1)`
  - avoid parser involvement in this flow to prevent stale/ambiguous selection state
- Avoid `Task.detached` for UI-owned workflows unless isolation boundaries are explicit and required.

### SwiftUI safety lessons
- Avoid hidden controls for keyboard shortcuts.
- Avoid `DispatchQueue.main.async` as a generic fix for publish-during-update warnings. The one justified use is `handleProjectorWindowClosed()` where `willCloseNotification` fires synchronously during `close()` and SwiftUI state mutation would re-enter the update cycle.
- Verse auto-scroll belongs to the native table. Reveal explicit navigation requests; coalesce resize-driven height updates after one layout pass with `Task.yield()`.
- Break complex `body` expressions into small subviews when type-checking slows down (e.g., `SearchResultRowView`).
- Do not place continuously dragged `Slider` controls inside `List` rows for this app's settings screen; prefer `VStack`/`GroupBox` layout with draft state + commit-on-edit-end to avoid sticky drag and heavy re-layout.

### Styling/HIG lessons
- Never hardcode blue for selection/highlight.
- Use accent-aware styling (`.accentColor` / `.foregroundColor(.accentColor)`).
- Keep loading feedback in the existing Live/Preview/Blank/Stop row with space reserved while idle. Use a static label; conditional spinners or extra progress rows above the verse table cause distracting layout shifts.

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
- Keep projector lifecycle ownership in shared `LiveProjectionController`. The user explicitly excluded introducing a projector `NSWindowController`; passage windows have their own controllers.
