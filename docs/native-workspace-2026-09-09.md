# Native AppKit workspace — September 9, 2026

The main interface now uses one AppKit controller hierarchy. This removes the SwiftUI navigation/list/focus bridges involved in the unresolved first-chapter-click report. The design uses native toolbar controls, split panes, selection, and text fields.

## Interface

- Books use a native outline sidebar with Old and New Testament groups.
- Chapters use an `NSCollectionView` of number-only buttons. The grid computes its column count from available width and fills the row evenly. Native arrow navigation follows the current arrangement.
- Bookmarks and History have separate resizable panes, dedicated reference rows, empty states, and action menus. Activating an entry loads, selects, and projects its verse in one action. History remains grouped by week; replaying an entry does not record it again.
- Verse rows and search results share the native reference table. Result headings show coordinates and translation matches. Keyboard result selection remains separate from projection activation.
- Search is a real `NSSearchToolbarItem`, accompanied by the Ref/Words/Phrase segmented control. Native control metrics determine text and icon alignment.
- Translation pickers sit directly above their respective verse columns, with the book and chapter centered between them on the same row. The projection status and Preview/Blank/Stop row sits above that heading. Display selection and presentation options are also native controls. Standard menu and responder commands include editing, bookmark Undo/Redo, search focus, sidebar toggling, settings, and help.

## Ownership

`ViewTheWordApp` starts `NSApplication`. `MainWindowController` owns the main window and window-level commands. `MainWorkspaceController` observes the existing Core models and services and is the only publisher of live projection. Snapshots update native controls silently; they never mirror or request focus.

The existing core database, navigation, search, import, and persistence logic remains in place. Projector lifecycle moved from the former SwiftUI `MainView` into the native root. Deferred close cleanup keeps the projection revision and window identity guards. Screen changes still use cancellable, coalesced repositioning. Browsing and live projection refresh remain independent.

The projector remains an owned `NSWindow`; no projector `NSWindowController` was introduced. Settings, help, projector preview, and projected content remain separate hosted SwiftUI screens. There are no SwiftUI representables inside the workspace.

## Validation and review

- Build with `xcodebuild -project ViewTheWord.xcodeproj -scheme ViewTheWord -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build`.
- Run `swift test --scratch-path build/SwiftPM -Xswiftc -strict-concurrency=complete` and `python3 scripts/test-review-regressions.py`.
- Run `scripts/render-navigation-review.sh` for the AppKit window-event regression and adaptive-layout fixtures. It requires a running AppKit application and key window; it does not mock key-window state or call a table's mouse handler directly.
- Run `scripts/render-projector-review.sh` for projected-output wrapping and fitting.

The window-event harness covers the first book-to-chapter click for four books, spatial grid arrows, toolbar search command routing, adaptive widths, and chapter reveal. Populated, scrolling Bookmarks and History fixtures verify that rows fill their panes and retain the same leading alignment at each width. Unit tests also cover the window's bookmark Undo chain, editing/caret preservation, search activation, and protection against stale deferred close cleanup.

Physical OS-delivered clicks and keyboard events, VoiceOver, Finder imports, HDMI reconnect, and Spaces remain manual checks. Computer-use permissions were unavailable in this session. Offscreen view caching does not fully capture macOS glass, including the floating book-sidebar surface, so the actual built app is the visual review target. See [manual validation](manual-validation.md).
