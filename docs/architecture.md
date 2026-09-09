# Architecture

ViewTheWord uses native AppKit controls for passage preparation and one shared live projector. Settings, help, preview, and projected content are separate hosted SwiftUI screens, excluded from passage tab groups.

## Application and state ownership

[ViewTheWordApp](../ViewTheWord/ViewTheWordApp.swift) starts `NSApplication`. `AppDelegate` retains `PassageTabsController` and the application updater. Passage windows can close independently of live output; reopening from the Dock restores access to its controls. Application termination shuts down output.

| Component | Responsibility |
| --- | --- |
| [PassageTabsController and MainWindowController](../ViewTheWord/AppKit/MainWindowController.swift) | The tab controller retains passage windows, including hidden and detached tabs, and provides shared projection, saved-reference stores, bookmark Undo, and update controls. Each window controller owns one workspace. |
| [MainWorkspaceController](../ViewTheWord/AppKit/MainWorkspaceController.swift) | Own each tab's native controls, query draft/mode/selection, testament filter, and navigation orchestration. |
| [VerseTargetModel](../ViewTheWord/Core/VerseTargetModel.swift) | Own a tab's navigation snapshot, search results, lazy readers, and cancellable preparation. Prepare projection data without opening windows or publishing live content. |
| [LiveProjectionController](../ViewTheWord/AppKit/WorkspaceProjection.swift) | Order projection intents across tabs, publish through `ProjectorViewModel`, and own the single projector `NSWindow` directly. |
| [BibleLibrary](../ViewTheWord/Core/BibleLibrary.swift) and [persistence stores](../ViewTheWord/Core/Persistence.swift) | Share translations, bookmarks, history, and recovery/error state across workspaces. |

Native tab groups own tab ordering and selection. Switching tabs preserves each workspace's controls, navigation, draft, results, caret, and scroll positions. Bookmarks, History, bookmark Undo, translations/preferences, and live output are shared. Preview is local to a tab and observes the shared projector model.

## Navigation and native controls

`VerseTargetModel.verseQuery` is derived from one published navigation snapshot containing the selected reference, complete chapter rows, and translation sources. Controls emit complete `VerseReference` intents. Chapter navigation uses those references directly, and verse-row projection validates that the reference exists in the loaded chapter. Verse numbers can differ between translations; row positions are not verse identities.

Snapshots update controls silently. Only explicit navigation may request focus, and only in the key passage window. Library replacement prompts claim the shared pending request before presenting so multiple tabs cannot show it at once.

- [Book, bookmark, and history sidebars](../ViewTheWord/AppKit/NativeSidebar.swift) use native rows. The pinned Old Testament / New Testament switch filters visible books independently in each tab; explicit reference navigation reveals the matching testament. Bookmarks and History have separate resizable panes.
- The [chapter grid](../ViewTheWord/AppKit/ChapterGridController.swift) adapts its column count to the available width. Arrow keys follow the spatial layout. After browsing a new book, Tab changes focus without navigating; the first arrow, Return, or Space opens chapter 1. Command-Left/Right moves between workspace columns.
- [Verse and search-result tables](../ViewTheWord/NativeReferenceTable.swift) use automatic row heights from constrained text fields. Resize-driven height updates are coalesced after layout. Bookmark refreshes preserve the viewport; an explicit reference submission reveals its verse again. Tab/Shift-Tab use AppKit's normal focus traversal.
- A real `NSSearchToolbarItem` hosts the [native search field](../ViewTheWord/NativeSearchField.swift). Editing preserves the draft until submission, and recent queries are separate for Ref, Words, and Phrase modes. Escape stops projection while preserving the draft.

Book/chapter browsing and Open in New Tab prepare a passage without projecting or capturing history. Ordinary verse selection projects. Search-result arrows only select; Return, Space, or a click activates projection. Bookmark and History activation loads, selects, and projects the reference, including reactivating the same row. Space compares the selected reference with the actual projected reference when toggling output.

## Live projection and window lifecycle

The shared live controller is the sole publisher through `ProjectorViewModel.project(_:owner:)` and `clearProjection()`. Typed `ProjectionOwner` values distinguish direct reference submissions, verse selections, and search results. Every passage observes the same Live, Blank, and pending-projection state.

A projection intent reserves a global generation before asynchronous preparation begins. A newer projection intent or Stop from any tab invalidates older preparation without canceling chapter browsing. Each navigation model also cancels its own superseded verse submission. Translation refresh uses a dedicated shared reader, preserves the live reference and blanking, and survives browsing or closure of the originating tab. An unavailable live reference stops output.

The live controller owns the projector window directly, without a projector `NSWindowController`. Closing the last passage tab leaves published output running. Stop calls `close()` on the projector; Escape from the projector's own event handler defers its close request to the next run-loop tick. State cleanup after `willCloseNotification` is also deferred to avoid re-entering AppKit/SwiftUI layout during teardown. Projection-revision and window-identity guards prevent stale cleanup from clearing a newer publication, replacement window, or pending request.

Screen changes use a cancellable, coalesced reposition task. Disconnected display preferences remain saved while output uses an available display. Blank hides content while retaining the window, and preview uses the output display's proportions. [Projected text layout](../ViewTheWord/Core/ProjectorTextLayout.swift) uses AppKit measurement followed by SwiftUI natural-height checks, without a fixed line-count cap.

## Bible data and persistence

The injectable `BibleReading` interface separates navigation from SQLite. [Database readers](../ViewTheWord/Db.swift) open lazily and keep all SQLite access on their private queues. Queries select named columns and identify verses by coordinates, independently of an imported `id` or column order.

Text search merges coordinates from both selected translations, fetches counterpart text, and uses cursor pagination with a lookahead. The [query parser](../ViewTheWord/RxVerse.swift) validates references and Words expressions; whole-word matching uses Unicode boundaries, while Phrase searches escape literal wildcard characters.

The shared library publishes catalog revisions after import, replacement, or removal. Imports snapshot committed SQLite/WAL data, normalize the copy, validate canonical coverage and coordinates, create a unique index, and install atomically. Replacement requires an explicit choice and removal uses Trash. See [Bible translation format](bible-format.md).

History capture is limited to direct reference submissions; replaying saved entries does not capture history. Bookmark changes use a shared UndoManager. Both stores preserve unreadable data as recovery copies and report persistence errors visibly.

## Updates and validation

One [AppUpdateController](../ViewTheWord/AppKit/AppUpdateController.swift) belongs to `AppDelegate` and is shared across passage toolbars. [SparkleUpdateDriver](../ViewTheWord/SparkleUpdateDriver.swift) owns the native update UI and installer integration; scheduled reminders preserve focus and projection, and installation requires user action. See [self-updates and release signing](self-updates.md).

The [build and test commands](../README.md#build-and-test) exercise the core, native controls, persistence, and shared projection. Tests inject readers that return canceled work to verify supersession and deferred cleanup; updater tests use an injected driver without network checks or installation.

The [navigation harness](../scripts/render-navigation-review.sh) launches a fixture app through LaunchServices with an injected translation catalog and a real AppKit event loop. It dispatches synthetic input through a key window to check tab state, navigation, focus, layout, and projection intent handling while suppressing projector windows. The [projector renderer](../scripts/render-projector-review.sh) checks output wrapping and fitting offscreen. Physical input, VoiceOver, display behavior, and complete update installation require the [manual validation checklist](manual-validation.md); offscreen caching does not fully capture native macOS glass.
