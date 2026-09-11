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
- `VERSION` is the sole app-version source; edit it directly or use `scripts/set-version.sh`. Xcode's `Generate versioned Info.plist` phase runs `scripts/generate-info-plist.sh` with declared VERSION/template/script inputs and a DerivedData output used by `INFOPLIST_FILE`. Never restore a checked-in version copy, a `MARKETING_VERSION` override, or post-processing of the signed app's plist. CI checks version generation and both built apps' versions.
- Maintainer release and notarization instructions live in `docs/releasing.md`. Keep the README focused on using and building the app, with a link to that guide.
- Resolve GitHub release tags through `git/ref/tags/<tag>` and follow annotated tag objects through `git/tags/<sha>` until reaching a commit. `commits/tags/<tag>` returns HTTP 422 even for an existing tag. Keep transport fixtures faithful to these API responses; lightweight tags need no extra lookup.
- Releases run on the maintainer's Mac via `make release`. `scripts/release.py` owns source preflight and the full release flow: it checks a clean source commit, the origin/update-feed destination, and the latest successful `Validate` push run on `master` for that exact commit; waits for running CI; signs/notarizes locally with the existing Keychain credentials; and only creates/pushes the derived `v<VERSION>` tag after artifacts are ready. Merge or push release changes to `master` and update the local checkout before releasing. Source, CI, tags, and the latest release are rechecked before publication. Never force-push tags or overwrite releases. Build numbers automatically advance past the previous signed feed. No version/tag/build overrides or validation bypasses. `make release-check` performs source/destination/CI checks only; `make release-notarize` produces signed local artifacts without tagging/publication. Artifacts live in `build/release/v<VERSION>/`. Plain `make` shows help; local `build` exports an Apple Silicon app to `~/Applications` and never cleans saved releases. `make clean` preserves `build/release/` and shares the release lock in Git’s common directory, including across linked worktrees; only build caches are removed and active releases block cleanup. The workflow validates PR updates and pushes to `master`; feature-branch pushes and release tags do not trigger it. Concurrency cancels superseded runs for the same PR or branch. PR, feature-branch, and tag runs cannot authorize a release. Preparation and publication are separate operations in `scripts/release.py`; `make release` calls both and resumes recorded work. `make release-publish` only publishes verified prepared artifacts. Keep `state.json` and `work/` in the version directory: they bind the archive, exported app, notarization submission, and final file checksums to one source commit and repository. Save Apple’s submission response before waiting; an unknown upload outcome requires explicit `--resume-notarization ID` recovery verified against Apple’s archive SHA-256. Publish via a draft carrying the saved release identity, verify uploaded digests (download and hash if absent), upload only missing assets, and publish last. Only an empty failed-upload placeholder on that matching draft may be deleted; never clobber an uploaded asset. A retry may recognize the exact already-published release without modifying it or making it latest again. Reject unrelated drafts, changed source/artifacts, and corrupt or unrecorded state. A newer master commit needs fresh preparation; the old validated commit can still finish its own release. Keep the shared local release/cleanup lock outside `build/` and separate `build/ReleaseDerivedData`. Separate clones or Macs still require one publisher at a time. A previous latest release without `appcast.xml` must stop preparation. Verify retained feed enclosure URLs/signatures/sizes and OS/hardware eligibility without rewriting signed XML. Run `python3 scripts/test-release-workflow.py` for offline orchestration regressions; keep signing credentials off CI.
- Release inputs require one HTTPS GitHub push URL and keep its exact spelling bound to saved state. Optional `NOTES_FILE` / `--notes` input must resolve outside the checkout and be readable before source preflight; use `/tmp/viewtheword-notes.md`. Keep directory checkpoints strict, including metadata inside saved packages. Respect Git’s tag-signing preference; a signing failure must preserve prepared artifacts. Malformed GitHub response bodies/types must stop with a readable error; only HTTP 404 means absent. Compare Apple’s archive SHA-256 case-insensitively while rejecting missing, malformed, or different digests.
- Regression commands: `swift test --scratch-path build/SwiftPM` and `python3 scripts/test-review-regressions.py`. Offscreen projector checks: `scripts/render-projector-review.sh`. See `docs/architecture.md` for state ownership and automated coverage, and `docs/manual-validation.md` for manual checks.

### Session handoff note (latest)
- Translation choices are local `PassageTranslations` values in each `MainWorkspaceController`. Each tab has labeled Primary and Secondary pickers; Secondary includes None and always remains visible. The internal `primaryOnly` flag and retained secondary URL keep saved preferences compatible. Preferred URLs survive catalog fallbacks and are optional when no choice has ever been available. Rendering and catalog refresh never rewrite them; only explicit selections replace preferences. New tabs/windows copy the opening/selected tab once; the first passage restores the last saved selection. Settings contains Display and Bible Library management only, with no translation selectors. `BibleLibrary` resolves effective sources by filename independently of saved defaults, restoring preferred translations when re-imported.
- Empty catalogs return no `BibleSources`, never a fake path or `/dev/null`. Show import instructions, disable translation pickers, and prevent navigation/search/projection from creating readers. Stop live output owned by an open tab with a shared explanation; importing restores browsing without automatically reopening stopped output.
- `LiveProjectionController` records each published `ProjectionSource` (tab ID and exact `BibleSources`) and transfers ownership only after successful publication. Only source-tab translation changes refresh the live reference, preserving blanking. Other tabs' changes cannot cancel pending projection; source refresh waits behind another tab's explicit intent and resumes only if still relevant. Closing the source tab detaches it while preserving output; an already-requested shared-reader refresh can finish, then output stays frozen until another projection or Stop.
- Live intents settle only through success/failure completion or a dedicated projection-cancellation callback. Never infer completion from `VerseTargetModel.isProjecting` in render/preference refresh. Clear cancellation callbacks before invoking them and before successful completion; invalidate the live token before canceling its model, including deferred window teardown.
- Native tab headings show the browsed reference and translation abbreviations, with full names in tooltips. Only the source tab gets a green `● Live` or muted `● Blanked` attributed-title marker, with plain status text preserved for accessibility. Native selected-tab styling stays intact. The shared footer continues to describe the actual projected verse independently of browsing.
- Search headings and tooltips use the same available `searchPage` as the table. Keep `searchRequest` after a failure for translation-change retries; it does not imply visible search results.
- Native Live/Blanked tab rendering in light/dark appearance and the empty-library screen were inspected through computer use in an isolated fixture on 2026-09-11. Projector windows were suppressed. Physical input, VoiceOver, and external-display behavior still require the manual checks.
- Space compares both the actual projected reference and its source translations. The same verse in another tab's different translations must project those translations; matching reference and translations toggles Stop.
- Navigation/search completions use `Result` for current-request success and failure; canceled or superseded requests remain silent. Empty chapters fail explicitly; fallback verses retain `requestedAvailable = false`. Failed submissions preserve draft/focus and never record history or publish.
- Return may resign the search editor before its target action and restore it afterward. `NativeSearchFieldController.isSendingSubmission` scopes that synchronous action; completion still checks the draft, interaction revision, and focus so later user activity wins.
- `SettingsWindowController` owns native library sheets across both Settings tabs. Closing Settings declines unresolved replacements, including active validation and queued Settings imports, while ordinary imports continue. Complete alert IDs idempotently; retain security-scoped URLs through the decision.
- Sanitized current-format history/bookmark files are persisted after successful recovery backup. Reloading repaired files must not create more recovery copies; backup failure still disables saving.
- Shared projection errors have a footer Dismiss action. Explicit Stop clears them; automatic stopping after an unavailable translation preserves the explanation. Projection failures must not leave a second copy in the originating navigation model.
- Chapter buttons restore their state from collection selection after activation, including repeated clicks on the selected chapter. The native harness checks one activation per click and a retained highlight.
- Asynchronous search/navigation completion may focus results only while the submitting draft, search editing session, and first responder are unchanged. AppKit's Return end-editing notification belongs to the submission itself; later edits or focus changes invalidate that focus request.
- Search pagination inserts appended rows without reloading existing row heights and preserves the visible reference plus offset. New searches and explicit verse reveals still scroll to the selection.
- Library imports queue every incoming URL, retaining security-scoped access through replacement decisions. Import alerts queue per presenter; passage tabs atomically claim alerts and complete them by ID after dismissal. Canceling or failing a replacement resumes the remaining files.
- Translation/catalog refreshes preserve each tab's browsed book and testament filter. Only explicit book/reference navigation reveals a testament. Valid row projection and projection retries clear obsolete navigation errors.
- The app requires macOS 26.0 or later in both the Xcode project and Swift package. CI uses `macos-26` with Xcode 26.5 selected through `DEVELOPER_DIR` and `actions/checkout@v7` on Node 24; keep the toolchain explicit.
- Self-updates use Sparkle 2.9.6, pinned in the Xcode project. `AppDelegate` owns one `AppUpdateController`, shared across passage toolbars; `SparkleUpdateDriver` owns Sparkle's native UI and installer. Scheduled checks only show an Update button; installation/restart requires user action. Preserve App Sandbox, installer/downloader XPC flags, Mach lookup entitlements, and signed-feed enforcement. The existing update signing key is in the maintainer's Keychain under account `suku.ViewTheWord`; only its public key belongs in Info.plist. Debug, Release, and local/release scripts build the app for arm64 only. CI verifies the main executable is arm64 only and all embedded Sparkle helpers contain arm64; keep prebuilt Sparkle binaries intact. After export, verify hardened runtime, DEVELOPMENT_TEAM, no debugging entitlement, and the app’s sandbox/Mach lookup entitlements and XPC flags. Publish a signed `appcast.xml` with increasing build numbers and Sparkle’s Apple Silicon hardware requirement; preserve compatible older feed entries. SwiftPM and the navigation harness use injected/offline update controls. See `docs/self-updates.md`.
- Passage tabs use native `NSWindow` tabbing, retained by `PassageTabsController`. Each tab keeps its full AppKit hierarchy, navigation model, query mode/draft/results/selection, and scroll positions. Native tab groups handle selection, dragging/reordering, detach, and merge.
- Command-T creates a tab; Command-Return and row context menus open the selected passage in a new tab without projection or history capture. Command-W closes a tab, Control-Tab/Control-Shift-Tab and Command-Shift-[/] switch tabs. Closing/switching tabs never stops already-published live output, even when the originating or last tab closes.
- Bookmarks, bookmark Undo, History, the translation catalog, appearance/output preferences, and live projection are shared. Translation selections belong to each tab. Every tab observes the same Live/Blank state. Preview is local to a tab and observes shared output. Only the active tab may request focus or present library alerts; a replacement prompt claims the shared pending request before presenting.
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
- Verse reveals wait for pending width-driven height invalidation and AppKit's automatic row measurements, including newly exposed neighbors. Center a verse that fits, align the start of an oversized verse to the top, and cancel superseded reveals. `scripts/render-navigation-review.sh --history-reveal-only` checks Psalm 117:2 → History Esther 8:9 at normal/compact sizes and with Secondary set to None.
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
- Native Bible picker items use URL `absoluteString` represented values; the Secondary picker's empty value means None. Translation selections are local values, never `AppStorage` bindings.
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
