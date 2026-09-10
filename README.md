# ViewTheWord

A local macOS app for browsing and projecting Bible verses in one or two translations. Requires macOS 26.0 or later. Malayalam BSI and English UKJV are included; an internet connection is not required.

## Getting started

1. Choose a book and chapter, or enter `John 3:16` in **Ref** mode and press Return. A submitted reference projects immediately; browsing a book or chapter only navigates. Activating a bookmark or history entry loads and projects its verse.
2. Click a verse to project it. In the verse list, Up/Down projects the previous/next verse; Option-Up/Down loads the previous/next chapter. Space toggles the selected verse's projection.
3. Select the output display in the projection controls. A disconnected preferred display stays saved and is restored when it reconnects. Auto uses an available display, so select an explicit display when using several screens.
4. Watch the **Live** reference and output display above the verse list. **Preview** shows the output layout; **Blank** hides the content while keeping the window open; **Stop** or Escape closes projection and cancels pending projection requests. With a transparent background, Blank reveals the underlying screen content.
5. Open Settings with Command-comma to adjust font sizes and padding or import translations. Primary Only hides the secondary translation in both browsing and projection. Changing translations preserves the live reference; projection stops if that reference is unavailable.

Use **Command-T** to keep another passage ready in a native tab. **Open in New Tab** in a reference's context menu (or **Command-Return** for the selected passage) prepares it without changing output. Switch with **Control-Tab / Control-Shift-Tab**, drag tabs to reorder, and close with **Command-W**. Each tab retains its navigation, search, and scrolling. Bookmarks, History, translations, and Live output are shared; closing the tab that projected a verse leaves output running.

The verse and chapter highlights show your current selection, including after projection stops. **Live** shows which reference is being projected when you browse elsewhere.

Use **View The Word → Check for Updates…** to download and install new releases.
Automatic checks show an **Update** button without interrupting your work; choose
the update and install it when you are ready to restart. You can turn automatic
checks off in the app menu. Existing users install the first version with this
feature manually. See [self-updates](docs/self-updates.md).

In the chapter grid, arrow keys follow the current arrangement and keep focus there. Return or Space opens the selected chapter again; Command-Left/Right moves between workspace columns. In the verse list, Command-Up/Down jumps five verses, Page Up/Down jumps ten, and Home/End selects the first/last verse. Left/Right moves from the verse list to another column or search.

Bookmarks are available from verse actions and appear with history beneath the chapter list. Only direct reference submissions are added to history. Adding, removing, and clearing bookmarks support Undo/Redo. If a stored history/bookmark file is unreadable, the app preserves a recovery copy and shows a message.

## Searching

In **Ref** mode, short book prefixes work: `p 1 1` opens Psalm 1:1, and `1p1 1` opens 1 Peter 1:1. When several book names match, the first book in Bible order is used. The chapter must exist in that book, so `1p140` is rejected.

Spaces, a colon, or a period can separate the chapter and verse. `psa 5 5` opens Psalm 5:5, and `psa 5` defaults to Psalm 5:1.

Choose **Words** or **Phrase** beside the search field:

| Input | Mode | Meaning |
| --- | --- | --- |
| `jesus mary` | Words | Both whole words, using implicit AND |
| `god OR love AND mercy` | Words | God, or both love and mercy |
| `love NOT hate` | Words | Love without hate |
| `god AND (love OR mercy)` | Words | Explicit grouping |
| `his only begotten son` | Phrase | Literal substring |
| `nt: faith AND hope` | Words | New Testament only |
| `john: light` | Either text mode | Only John |

NOT binds before AND, then OR. Parentheses change that order. Phrase search treats `%` and `_` literally. Filters also include `ot:`. Malformed expressions and unsupported reference ranges produce an explanation instead of silently changing the query.

Search matches either selected translation and shows the counterpart translation for each verse. Results are ordered by book/chapter/verse. `100+ results` means more are available through **Load more results**. Arrow keys select a result; Return, Space, or clicking projects it. Command-L returns focus to search. Tab and Shift-Tab follow normal macOS control navigation.

The native search field submits on Return or the search action. Its magnifying-glass menu lists recent queries for the current search mode. The cancel button clears the draft and pending browsing/search; Escape stops projection and preserves the draft. These recent queries are separate from the saved verse history.

## Translations

Use **Settings → Bible → Import Bible**, or open a `.bible` file with ViewTheWord. Primary and secondary translation pickers in Settings remain available while viewing search results. Imported translations immediately appear in every picker. Re-importing a filename offers replacement; the existing copy survives a failed validation. Remove moves an imported translation to Trash. Included translations cannot be replaced.

The app validates and indexes a private copy of each import. Translation numbering can differ: missing verses fall back to another available row for navigation, while unavailable live references stop projection. See [the file format and converter guide](docs/bible-format.md) for producing `.bible` files.

## Build and test

Open `ViewTheWord.xcodeproj` in Xcode 26.5 or later, choose the ViewTheWord scheme, and configure your signing team. CI uses macOS 26 with Xcode 26.5 selected explicitly. For a local build without a configured signing certificate:

```bash
xcodebuild -project ViewTheWord.xcodeproj -scheme ViewTheWord -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
swift test --scratch-path build/SwiftPM
python3 scripts/test-review-regressions.py
python3 scripts/test-release-workflow.py
```

The Swift package tests the same parser, database, import, navigation, projection preparation, persistence, text fitting, and native reference-table sources used by the app. Native tests exercise keyboard events, focus, scroll restoration, and row actions. CI runs these checks plus Debug and Release builds once per PR update and on pushes to `master`; feature-branch pushes and release tags do not start a second run. New commits cancel older runs for the same PR or branch. [Manual checks](docs/manual-validation.md) cover physical keyboard/VoiceOver behavior and displays.

With local Xcode signing configured, `make build` exports a universal app to `~/Applications`; `make build-for-this` builds only for this Mac's architecture. Run `make` to list commands, or `make clean` to delete `build/`.

The layered VTW app icon is editable in Icon Composer. See [the icon source and rendering guide](docs/app-icon.md) for appearance previews and build integration.

The passage workspace uses native AppKit controls and an independent navigation model for each tab. One shared `LiveProjectionController` publishes output and owns the projector window. Settings, help, preview, and projected content are separate SwiftUI screens. See [the architecture guide](docs/architecture.md) for state ownership, navigation, data access, and validation boundaries.

Maintainers can find signing, notarization, and publishing instructions in the [release guide](docs/releasing.md).
