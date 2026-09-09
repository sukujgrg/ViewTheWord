# Review implementation — 7 September 2026

> Workspace architecture update: the September 9 [native workspace migration](native-workspace-2026-09-09.md) supersedes the SwiftUI workspace and focus-bridge details below. The original data, persistence, and projector fixes remain in place.

This change implements the 17 numbered findings in `build/review/2026-09-07-app-review.md`, reviewed against commit `57e8774`, plus the supporting architecture, performance, recovery, and operator improvements. The app retains its SwiftUI/AppKit architecture. MainView continues to own projected content and window lifecycle.

## Finding-by-finding changes

| Finding | Implemented behavior | Main coverage |
| --- | --- | --- |
| 1 — Chapter shortcut/reference mismatch | Chapter shortcuts emit complete reference intents. A single navigation snapshot commits the reference, chapter rows, and translation identities. Row projection validates the complete cached reference. | Atomic/out-of-order navigation and mismatched-coordinate tests |
| 2 — Numeric overflow and partial parsing | Anchored reference parsing accepts compact and space-separated references, resolving short book prefixes to the first match in Bible order. It rejects overflow, negative values, unsupported ranges, trailing text, unknown books, and chapters outside the selected book's limits. SQLite bindings use checked numeric conversion. | QueryTests |
| 3 — Secondary-only matches disappear | Search unions coordinates from both translations, fetches counterpart verses, retains which translation matched, and labels fallback projection correctly. | Real Malayalam/English `jesus` search and paired results |
| 4 — Settings change the live target | Navigation refresh uses its typed reference; live refresh uses ProjectionOwner. Neither reparses the editable draft. Blank state survives translation refresh. Settings includes translation pickers while search results are open. | Independent browse/live refresh and owner-preservation tests |
| 5 — Delayed projection reopens after Escape | Projection generations invalidate old work. Navigation-owned projection requests and independent live refresh are tracked separately. Window-close cleanup remains deferred; generation, projection revision, and window identity protect newer requests. | Escape, out-of-order completion, superseded submission, and deferred-close tests |
| 6 — Accepted schema cannot be read | All queries select the four required columns by name. Identity comes from coordinates, not `id`. Import validates integer types, range, uniqueness, canonical coverage, and integrity. | Reordered/no-id schema, invalid coordinates, atomic replacement, and WAL tests |
| 7 — Expression tokens silently discarded | Words search consumes all tokens, accepts implicit AND, implements NOT > AND > OR, and reports incomplete operators, quotes, and parentheses. Input complexity is bounded. | QueryTests |
| 8 — Missing boundaries and LIKE wildcards | A cached Unicode matcher handles letters, combining marks, numbers, joiners, and punctuation. Phrase search escapes `%`, `_`, and backslash. | Unicode boundary tests; real Matthew 1:21 `JESUS:` match; literal wildcard fixture |
| 9 — Missing verses leave stale translations | Chapter loading completes independently of target availability. Navigation selects an available fallback; an unavailable live reference stops projection. Rows from the previous source are hidden while new translations load. | 3 John 1:15 → Primary Only regression |
| 10 — History depends on search mode | History activates a validated reference directly. Legacy reference strings normalize to canonical titles; invalid data is preserved for recovery. Capture remains restricted to direct reference submissions. | Legacy history and invalid-reference recovery tests |
| 11 — Same chapter after changing books | Native chapter rows support selection, same-row click, and Return/Space activation. Programmatic selection emits no intent. Navigation always includes the book. | Same-number/different-book navigation and native event tests; physical click/focus still manual |
| 12 — Import does not refresh pickers | BibleLibrary publishes available URLs and a revision to all pickers and consumers. Import/replacement/removal refresh active navigation and search. | Shared library wiring; import service tests; mounted picker interaction still manual |
| 13 — Disconnection clears display preference | Preferred display ID stays saved. Fallback resolution is separate; menus retain and identify a disconnected preference. Deferred/coalesced repositioning remains. | Source verification; physical display tests still manual |
| 14 — Hidden 100-result limit | Search reads a page plus lookahead, merges canonically, and uses a coordinate cursor. Counts show `+` when more exist; Load more retains selection and previous results. | Full bundled `love` search compared with paginated results, without skips or duplicates |
| 15 — Search cannot be activated by keyboard | Search results are selectable Buttons with Return/Space activation, labels, and focus after completion. Tab uses normal macOS traversal. Verse rows also expose a Project accessibility action. | Source/build checks; VoiceOver and interactive focus still manual |
| 16 — Release artifact/tag mismatch | Preflight requires a clean tree and HEAD equal to the local release tag, then rechecks after archiving. GitHub publication verifies the destination tag, adds source-commit metadata, and refuses to overwrite an existing release. | Temporary Git repository regressions; no signing, notarization, or publication performed |
| 17 — Different default font sizes | Shared keys/defaults set verse text to 100 points, reference text to 36, and padding to 20. All numeric storage remains Double; sliders remain draft-backed. | Shared source declarations and successful app builds |

## Supporting improvements

- `Core/VerseTargetModel.swift` owns lazy readers through the injectable `BibleReading` interface. All SQLite work, including open/close and cached chapter statements, stays on each reader's private queue. UI models are explicitly isolated to MainActor, and the application enables complete strict-concurrency checking.
- Both included databases now have a unique `(bnumber, cnumber, vnumber)` index. Every table's contents were compared with the original Git versions and are unchanged; each Bible still contains 31,102 verses. Integrity checks pass and single-verse lookup plans use the index.
- Imports use a consistent SQLite backup, including committed WAL data, then normalize to a standalone database before validation and indexing. The XML converter also indexes output and preserves existing files on failed overwrite.
- Persistence preserves unreadable or invalid originals as recovery copies and shows failures. Valid history entries are normalized and deduplicated. Clearing bookmarks supports Undo/Redo.
- Operators see the live reference, resolved output display, Stop, Blank/Unblank, and a preview. AppKit measures text, then SwiftUI verifies natural height; the ten-line cap is gone. Fractional-width and font-fallback cases found during rendering were corrected. Very small displays with large padding can still produce text too small to read at a distance; preview and venue checks remain necessary.
- Translation names are readable. Settings supports deliberate replacement and removal of imports, and Finder file opening routes into the shared import workflow. Technical format requirements moved to `docs/bible-format.md`.
- Normal Xcode builds use `Config/Version.xcconfig`, generated alongside VERSION by `scripts/set-version.sh`. The current normal-build version is 3.0.5. The unused outgoing-network capability was removed.
- Added a Swift package test target, converter/release regression script, macOS CI workflow, a repeatable offscreen projector renderer, onboarding documentation, and a focused follow-up list.

## Navigation follow-up — 9 September 2026

An offscreen reproduction confirmed that positional verse-row identities could preserve the previous chapter's text and highlight after the header changed. Rows and scroll targets now use complete verse coordinates. Re-running the same fixture with the old positional IDs reproduces the stale rows; coordinate IDs update them correctly.

Verse and current-chapter highlights follow the selected navigation reference, independently of the live projection and keyboard focus. Row activation synchronizes the sidebar and focuses the verse list. Space still checks the projected reference when toggling projection.

The unsigned Debug build and 30 Swift tests pass. `scripts/render-navigation-review.sh` renders seven states covering browsing, projection, the next verse, another chapter, stopped projection, another book, and returning to the original chapter. All seven were visually inspected. The fixture uses the actual views and controls with sample text; physical key delivery and VoiceOver remain part of the manual checks.

## AppKit navigation migration — 9 September 2026

The verse and chapter lists now use `NSTableView` through `NativeReferenceTable.swift`. Their text fields, row reuse, selection drawing, scrolling, context menus, and keyboard handling are native AppKit. SwiftUI retains translation controls and the rest of the interface. Native callbacks emit complete references; MainView remains the only publisher of projected content and owner of its window.

Applying a model snapshot cannot trigger selection navigation. Native selection draws the accent highlight even when focus is elsewhere or projection has stopped. Chapter arrow navigation keeps chapter focus, while verse arrows project the selected reference. Existing chapter, projection, focus, and jump shortcuts remain available. Focus requests occur on column changes, and bookmark refreshes preserve the viewport; a repeated reference submission still reveals the selected verse.

Row heights account for both translations, width, and font size. Resize updates run after AppKit's layout pass with implicit height animation disabled; row selection delegates do not reconfigure views. Copy/bookmark menus capture complete references, and native rows expose Project verse/Open chapter accessibility actions.

The migration adds native-event, focus, wrapping, scroll, context-menu, and accessibility-action coverage. All 41 Swift tests and three Python regressions pass. Unsigned Debug and Release builds pass, with no application-source warnings. `git diff --check` passes. `scripts/render-navigation-review.sh` includes seven selection transitions plus three real Malayalam/English layouts at different widths, font sizes, and translation modes; all ten were rendered and visually inspected, with native row-frame assertions passing and no AppKit re-entry warnings. Physical keyboard delivery and VoiceOver remain manual checks.

## Subsequent AppKit fixes — 9 September 2026

- Native reference tables now use automatic row heights and constrained text fields. Wrapping is calculated by NSTextField itself; the separate NSString measurement and height cache are removed. Vertical constraints let bilingual rows grow and shrink during resizing. Bookmark-only changes refresh cells without reloading the table or moving the viewport.
- Standard table movement, Return, Escape, and Copy use responder actions. AppKit interprets standard key bindings, including Control-N; Command/Option-arrow jumps and the Space projection toggle keep their existing behavior. Copy menu validation follows selection, translation availability, and loading state.
- The query control is a single NSSearchField with whole-query submission, a native cancel button, and separate recent-query menus for each mode. Responsive layout preserves field identity and insertion position. Escape preserves the draft and emits Stop. Native cancel-button action notifications are deduplicated so clearing happens once.
- Bookmark add, remove, and clear use the same undo manager. Undo reverses individual edits and also preserves subsequent edits made without that manager; changes persist through Undo and Redo.
- Validation: all 50 Swift tests pass with complete strict-concurrency checking; the unsigned Debug build, three Python regressions, and diff whitespace checks pass. Thirteen offscreen navigation/search fixtures pass, including the John 3:16 clipping reproduction, native text-field sizing assertions, and search identity/caret checks across wide and compact layouts. Projector window ownership and lifecycle remain in MainView. Physical keyboard/VoiceOver and external-display checks remain manual.

## Initial review validation

The following results describe the initial review implementation, before the native-table migration. The archived distribution artifact below predates that migration.

- 30 Swift tests pass with strict concurrency checking, including short book prefixes and chapter limits, plus readers that deliberately ignore cancellation to test stale completion handling.
- Three Python regression tests pass: converter replacement/indexing, version consistency, and release source verification in an isolated Git repository.
- Shell syntax and `git diff --check` pass.
- Unsigned Debug and Release builds pass. The final unsigned Release archive at `build/review/ViewTheWord-reviewed.xcarchive` also passes and contains both `arm64` and `x86_64`. Its bundle version is 3.0.5 and its source marker is `development`, as expected for this uncommitted validation build.
- Five offscreen fixtures were rendered and visually inspected: dual 1920×1080, stacked 1024×768 with large padding, dual 640×480 with large padding, mixed Hebrew/English direction, and blank output. Verse text fits in these fixtures; the small-screen translation-name label may truncate. Images are in `build/review/rendered`, regenerable with `scripts/render-projector-review.sh`.
- No application-source strict-concurrency warnings remain. The environment emits unrelated simulator-service/cache messages and the normal skipped-AppIntents-metadata warning.

Interactive keyboard/VoiceOver behavior, Finder opening, physical HDMI reconnect/fullscreen Spaces, venue readability, and signed distribution have not been exercised. Follow `docs/manual-validation.md`. CI is configured but has not run on GitHub in this local implementation session.

The GitHub source check uses the documented [Get a commit endpoint with a tag reference](https://docs.github.com/en/rest/commits/commits#get-a-commit). It does not publish or change a release during validation.
