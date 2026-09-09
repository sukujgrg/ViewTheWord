# ViewTheWord

A local macOS app for browsing and projecting Bible verses in one or two translations. Requires macOS 14 or later. Malayalam BSI and English UKJV are included; an internet connection is not required.

## Getting started

1. Choose a book and chapter, or enter `John 3:16` in **Ref** mode and press Return. A submitted reference projects immediately; browsing a chapter or opening a bookmark/history entry only navigates.
2. Click a verse to project it. In the verse list, Up/Down projects the previous/next verse; Option-Up/Down loads the previous/next chapter. Space toggles the selected verse's projection.
3. Select the output display in the projection controls. A disconnected preferred display stays saved and is restored when it reconnects. Auto uses an available display, so select an explicit display when using several screens.
4. Watch the **Live** reference and output display above the verse list. **Preview** shows the output layout; **Blank** hides the content while keeping the window open; **Stop** or Escape closes projection and cancels pending projection requests. With a transparent background, Blank reveals the underlying screen content.
5. Open Settings with Command-comma to adjust font sizes and padding or import translations. Primary Only hides the secondary translation in both browsing and projection. Changing translations preserves the live reference; projection stops if that reference is unavailable.

Use **Command-T** to keep another passage ready in a native tab. **Open in New Tab** in a reference's context menu (or **Command-Return** for the selected passage) prepares it without changing output. Switch with **Control-Tab / Control-Shift-Tab**, drag tabs to reorder, and close with **Command-W**. Each tab retains its navigation, search, and scrolling. Bookmarks, History, translations, and Live output are shared; closing the tab that projected a verse leaves output running.

The verse and chapter highlights show your current selection, including after projection stops. **Live** shows which reference is being projected when you browse elsewhere.

In the chapter list, Up/Down opens the previous/next chapter and keeps focus there. Return or Space opens the selected chapter again. In the verse list, Command-Up/Down jumps five verses, Page Up/Down jumps ten, and Home/End selects the first/last verse. Outside the search field, Left/Right moves between columns and search.

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

Open `ViewTheWord.xcodeproj` in Xcode, choose the ViewTheWord scheme, and configure your signing team. For a local build without a configured signing certificate:

```bash
xcodebuild -project ViewTheWord.xcodeproj -scheme ViewTheWord -configuration Debug -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
swift test --scratch-path build/SwiftPM
python3 scripts/test-review-regressions.py
```

The Swift package tests the same parser, database, import, navigation, projection preparation, persistence, text fitting, and native reference-table sources used by the app. Native tests exercise keyboard events, focus, scroll restoration, and row actions. CI runs these checks plus Debug and Release builds. [Manual checks](docs/manual-validation.md) cover physical keyboard/VoiceOver behavior and displays.

The main workspace uses AppKit throughout: a native toolbar and search field, a book sidebar, an adaptive chapter-number grid, separate Bookmarks and History panes, and native verse/search-result tables. AppKit owns first responder, selection, scrolling, and row reuse. Settings, help, preview, and projected output remain isolated SwiftUI screens. `VerseTargetModel` commits selected references, chapter rows, and translation identities together; `MainWorkspaceController` owns each tab’s navigation; shared `LiveProjectionController` alone publishes projected content and owns projector lifecycle. `PassageTabsController` retains the native passage windows and shared services. Database connections open lazily on private queues. See [the native workspace migration](docs/native-workspace-2026-09-09.md).

## Release and notarize

Change versions with `./scripts/set-version.sh 3.1.0`; commit both `VERSION` and `Config/Version.xcconfig` along with the release changes, then create the corresponding Git tag. Xcode uses the generated version configuration for ordinary builds too. Optional `vX.Y.Z+BUILD` tags also set the build number.

Store notarization credentials once:

```bash
xcrun notarytool store-credentials "ViewTheWordNotary" \
  --apple-id "you@example.com" \
  --team-id "YOURTEAMID" \
  --password "app-specific-password"
```

From a clean checkout at the release tag:

```bash
make release-notarize NOTARY_PROFILE=ViewTheWordNotary TAG=v3.1.0
```

To publish, push that exact tag to the destination repository first, then run:

```bash
make release-github NOTARY_PROFILE=ViewTheWordNotary GH_REPO=sukujgrg/ViewTheWord TAG=v3.1.0
```

The script verifies a clean tree, HEAD equal to the tag, version consistency, and the matching GitHub tag before publishing. Existing releases are not overwritten. Artifacts in `build/release` include the app, notarized zip, checksum, and source-commit metadata. Signing, notarization, and publishing require the appropriate local credentials.
