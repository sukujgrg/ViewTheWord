import AppKit

private func reviewLog(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

@main
struct NativeWorkspaceReview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await review()
                let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
                try Data("PASS\n".utf8).write(to: root.appendingPathComponent("build/review/navigation/passed"))
                exit(0)
            }
            catch { reviewLog("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }
    @MainActor static func review() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("build/review/navigation", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ViewTheWord.NativeWorkspaceReview")!
        defaults.removePersistentDomain(forName: "ViewTheWord.NativeWorkspaceReview")
        defaults.set(17.0, forKey: AppDefaultsKey.verseRowFontSize)
        let sources = BibleSources(primary: root.appendingPathComponent("ViewTheWord/Resources/MAL_BSI.bible"),
                                   secondary: root.appendingPathComponent("ViewTheWord/Resources/ENG_UKJV.bible"), revision: 1)
        NSWindow.allowsAutomaticWindowTabbing = false
        let menuDelegate = AppDelegate()
        menuDelegate.buildMenu()
        defer { withExtendedLifetime(menuDelegate) {} }
        let live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [sources.primary, sources.secondary!]), defaults: defaults, sourceResolver: { primaryOnly in
            BibleSources(primary: sources.primary, secondary: primaryOnly ? nil : sources.secondary, revision: 1)
        })
        // Exercise logical output lifetime without sending fixture content to a display.
        var outputCreations = 0
        live.projectorWindowFactory = { _ in outputCreations += 1; return nil }
        let tabs = PassageTabsController(liveProjection: live,
            history: HistoryStore(fileURL: output.appendingPathComponent("history.json")),
            bookmarks: BookmarkStore(fileURL: output.appendingPathComponent("bookmarks.json")), savesFrames: false)
        let controller = tabs.open()
        let workspace = controller.workspace
        workspace.history.clear()
        workspace.bookmarks.clear()
        let savedReferences = [("Joshua", 7, 17), ("Joshua", 7, 18), ("1 Samuel", 12, 3),
                               ("Ecclesiastes", 8, 8), ("Ecclesiastes", 8, 10), ("Ecclesiastes", 8, 17),
                               ("Ezra", 10, 42), ("Zechariah", 14, 6), ("Ephesians", 6, 8),
                               ("Psalm", 23, 1), ("John", 3, 16), ("Romans", 8, 28)]
            .map { VerseReference(book: $0.0, chapter: $0.1, verse: $0.2)! }
        for reference in savedReferences {
            workspace.bookmarks.add(reference)
            workspace.history.append(reference.verseQuery.title)
        }
        let window = controller.window!
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for attempt in 0..<100 {
            if NSApp.isActive && window.isKeyWindow { break }
            if attempt % 10 == 0 {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(NSApp.isRunning && NSApp.isActive && window.isKeyWindow,
                     "Window-event checks require a running AppKit application: running=\(NSApp.isRunning), active=\(NSApp.isActive), key=\(NSApp.keyWindow?.title ?? "nil"), visible=\(window.isVisible)")
        try await checkNavigation(workspace, window: window)
        try await checkSavedActivation(workspace, window: window)
        defer { tabs.shutdown(); for tab in tabs.windows { tab.close() }; defaults.removePersistentDomain(forName: "ViewTheWord.NativeWorkspaceReview") }
        try await checkPassageTabs(tabs, original: controller, output: output, outputCreations: { outputCreations })
        try await checkTabCancellation(output: output)
        window.makeKeyAndOrderFront(nil)
        try await settle(workspace)
        var counts = Set<Int>()
        var savedTextOrigins: [String: CGFloat] = [:]
        for (name, width, dark, size, chapterWidth) in [("native-workspace-light", 1200.0, false, 17.0, 220.0),
                                           ("native-workspace-dark", 1200.0, true, 17.0, 320.0),
                                           ("native-workspace-compact", 950.0, false, 20.0, 165.0)] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setContentSize(NSSize(width: width, height: 760))
            window.contentView?.layoutSubtreeIfNeeded()
            let start = workspace.chapterSplit.view.convert(workspace.chapterSplit.view.bounds, to: workspace.split.splitView).minX
            workspace.split.splitView.setPosition(start + chapterWidth, ofDividerAt: 1)
            defaults.set(size, forKey: AppDefaultsKey.verseRowFontSize)
            workspace.navigate(to: VerseReference(book: "Psalm", chapter: 119, verse: 53)!, focusVerses: false)
            for _ in 0..<100 where workspace.navigation.isLoading { try await Task.sleep(nanoseconds: 10_000_000) }
            workspace.render()
            try await Task.sleep(nanoseconds: 300_000_000)
            if dark { workspace.focus(.verses) }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for saved in [workspace.savedBookmarks, workspace.savedHistory] {
                let origin = checkSavedPane(saved, in: workspace.chapterSplit.view)
                let label = saved.outline.accessibilityLabel()!
                if let previous = savedTextOrigins[label] {
                    precondition(abs(origin - previous) < 1, "Saved row leading alignment must stay fixed when resizing")
                }
                savedTextOrigins[label] = origin
            }
            let chapterFrame = workspace.chapters.collection.collectionViewLayout!.layoutAttributesForItem(at: IndexPath(item: 118, section: 0))!.frame
            precondition(workspace.chapters.collection.visibleRect.intersects(chapterFrame), "Target chapter must be revealed in the grid")
            precondition(workspace.navigation.navigation.reference == VerseReference(book: "Psalm", chapter: 119, verse: 53))
            precondition(workspace.verses.table.selectedRow == 52)
            let field = workspace.search.field
            precondition(field.window === window && field.frame.width > 150, "Search must remain visible in the native toolbar")
            let frame = window.contentView!.superview!
            let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            let savedPane = workspace.chapterSplit.view
            let paneBitmap = savedPane.bitmapImageRepForCachingDisplay(in: savedPane.bounds)!
            savedPane.cacheDisplay(in: savedPane.bounds, to: paneBitmap)
            try paneBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + "-saved.png"))
            counts.insert(workspace.chapters.columnCount)
            reviewLog("PASS \(name): \(workspace.chapters.columnCount) chapter columns, native toolbar, Psalm 119:53, bilingual text")
        }
        precondition(counts.count >= 2, "Chapter columns must adapt to pane width")
    }
    @MainActor static func checkPassageTabs(_ tabs: PassageTabsController, original: MainWindowController,
                                           output: URL, outputCreations: () -> Int) async throws {
        let first = original.workspace
        let firstWindow = original.window!
        let john = VerseReference(book: "John", chapter: 3, verse: 16)!
        let psalm = VerseReference(book: "Psalm", chapter: 23, verse: 1)!
        let romans = VerseReference(book: "Romans", chapter: 8, verse: 28)!
        let live = tabs.liveProjection
        first.navigate(to: john, project: true, focusVerses: false)
        try await settle(first)
        let outputCount = outputCreations()
        let revision = live.projector.revision
        first.verses.table.scrollRowToVisible(first.verses.rows.count - 1)
        first.focusSearch(nil)
        first.search.field.stringValue = "John draft for later"
        first.search.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: first.search.field))
        let editor = first.search.field.currentEditor() as! NSTextView
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        try await settle(first)
        let scroll = first.verses.scrollView.contentView.bounds.origin
        let topRow = first.verses.table.row(at: NSPoint(x: 20, y: scroll.y + 1))
        let topOffset = scroll.y - first.verses.table.rect(ofRow: topRow).minY
        let rows = first.verses.rows

        // Standard menu key equivalents route through the real toolbar responder.
        command("t", modifiers: .command, code: 17, window: firstWindow)
        precondition(tabs.windows.count == 2, "Command-T creates a passage tab")
        let empty = tabs.selected!
        precondition(empty.workspace.navigation.navigation.chapter == nil)
        precondition(empty.window!.tabGroup === firstWindow.tabGroup)
        command("w", modifiers: .command, code: 13, window: empty.window!)
        try await settle(first)
        precondition(tabs.windows.count == 1 && live.projector.revision == revision,
                     "Closing a preparation tab must leave output untouched")

        // A context action captures its reference without selecting/projecting it.
        let savedNode = first.savedBookmarks.nodes.first { $0.reference == psalm }!
        invoke("Open in New Tab", in: first.savedMenu(for: savedNode)!)
        let second = tabs.selected!
        try await settle(second.workspace)
        precondition(second.window!.tab.title == "Psalm 23")
        precondition(firstWindow.tab.title == "John 3")
        precondition(firstWindow.tabGroup?.windows.count == 2)
        precondition(second.workspace.navigation.navigation.reference == psalm)
        precondition(first.navigation.navigation.reference == john && first.verses.rows == rows)
        precondition(live.projector.revision == revision, "Open in New Tab only prepares the passage")
        precondition(first.history === second.workspace.history && first.bookmarks === second.workspace.bookmarks)
        precondition(first.library === second.workspace.library && first.defaults === second.workspace.defaults)
        precondition(firstWindow.undoManager === second.window!.undoManager)
        let historyBefore = first.history.entries

        command("\t", modifiers: [.control, .shift], code: 48, window: second.window!)
        try await settle(first)
        for _ in 0..<100 {
            if firstWindow.isKeyWindow { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(tabs.selected === original && firstWindow.isKeyWindow,
                     "Previous tab must become key: selected=\(tabs.selected?.window?.title ?? "nil"), key=\(NSApp.keyWindow?.title ?? "nil"), group=\(firstWindow.tabGroup?.selectedWindow?.title ?? "nil")")
        precondition(first.draft == "John draft for later" && first.search.field.stringValue == first.draft)
        let restoredScroll = first.verses.scrollView.contentView.bounds.origin
        let restoredTop = first.verses.table.row(at: NSPoint(x: 20, y: restoredScroll.y + 1))
        let restoredOffset = restoredScroll.y - first.verses.table.rect(ofRow: restoredTop).minY
        precondition(restoredTop == topRow && abs(topOffset - restoredOffset) < 1,
                     "Switching preserves viewport content: row \(topRow)+\(topOffset) at \(scroll) → row \(restoredTop)+\(restoredOffset) at \(restoredScroll)")
        precondition((first.search.field.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 5, length: 0),
                     "Native tabs preserve the search insertion point")
        command("\t", modifiers: .control, code: 48, window: firstWindow)
        try await settle(second.workspace)
        precondition(tabs.selected === second && live.projector.revision == revision)

        let secondWorkspace = second.workspace
        let verseRow = 1
        secondWorkspace.verses.table.scrollRowToVisible(verseRow)
        second.window!.contentView?.layoutSubtreeIfNeeded()
        click(secondWorkspace.verses.table, rect: secondWorkspace.verses.table.rect(ofRow: verseRow), window: second.window!)
        try await settle(secondWorkspace)
        precondition(live.projector.projectionOwner?.reference == VerseReference(book: "Psalm", chapter: 23, verse: 2))
        first.render()
        precondition(first.statusLabel.stringValue == secondWorkspace.statusLabel.stringValue)
        precondition(first.previewButton.isEnabled && first.blankButton.isEnabled && first.stopButton.isEnabled)
        click(secondWorkspace.blankButton, rect: secondWorkspace.blankButton.bounds, window: second.window!)
        try await settle(secondWorkspace)
        first.render()
        precondition(live.projector.isBlanked && first.blankButton.title == "Unblank")
        click(secondWorkspace.blankButton, rect: secondWorkspace.blankButton.bounds, window: second.window!)
        try await settle(secondWorkspace)
        // Preview is hosted locally and observes the same shared projector model.
        click(secondWorkspace.previewButton, rect: secondWorkspace.previewButton.bounds, window: second.window!)
        precondition(secondWorkspace.preview.isShown)
        secondWorkspace.preview.performClose(nil)

        activateSaved(psalm, in: secondWorkspace.savedBookmarks, window: second.window!)
        try await settle(secondWorkspace)
        command("\t", modifiers: [.control, .shift], code: 48, window: second.window!)
        try await settle(first)
        click(first.stopButton, rect: first.stopButton.bounds, window: firstWindow)
        try await settle(first)
        precondition(live.projector.projectionOwner == nil)
        command("\t", modifiers: .control, code: 48, window: firstWindow)
        try await settle(secondWorkspace)
        activateSaved(psalm, in: secondWorkspace.savedBookmarks, window: second.window!)
        try await settle(secondWorkspace)
        precondition(live.projector.projectionOwner?.reference == psalm, "Same saved item resumes after Stop from another tab")
        let resumedCount = outputCreations()
        precondition(resumedCount == outputCount + 1)

        let historyNode = secondWorkspace.savedHistory.nodes.flatMap { $0.children ?? [] }.first { $0.reference == romans }!
        let beforeNewTab = live.projector.revision
        invoke("Open in New Tab", in: secondWorkspace.savedMenu(for: historyNode)!)
        let third = tabs.selected!
        try await settle(third.workspace)
        precondition(third.window!.tab.title == "Romans 8" && live.projector.revision == beforeNewTab)
        activateSaved(romans, in: third.workspace.savedHistory, window: third.window!)
        try await settle(third.workspace)
        precondition(live.projector.projectionOwner?.reference == romans)
        precondition(first.history.entries == historyBefore, "Saved activations in all tabs remain history-neutral")
        precondition(NSApp.sendAction(#selector(MainWindowController.moveTabLeft(_:)), to: nil, from: nil))
        precondition(firstWindow.tabGroup?.windows.map(\.tab.title) == ["John 3", "Romans 8", "Psalm 23"])
        precondition(NSApp.sendAction(#selector(MainWindowController.moveTabRight(_:)), to: nil, from: nil))
        precondition(firstWindow.tabGroup?.windows.map(\.tab.title) == ["John 3", "Psalm 23", "Romans 8"])
        precondition(outputCreations() == resumedCount, "All passages share one output lifetime")
        let frame = third.window!.contentView!.superview!
        frame.layoutSubtreeIfNeeded()
        let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("native-passage-tabs.png"))

        third.workspace.changeSearchMode(.wordSearch)
        third.workspace.search.field.stringValue = "john: light"
        third.workspace.search.field.sendAction(third.workspace.search.field.action, to: third.workspace.search.field.target)
        try await settle(third.workspace)
        precondition(third.workspace.navigation.searchPage != nil && third.workspace.verses.rows.count > 1)
        third.workspace.verses.table.moveDown(nil)
        let selectedResult = third.workspace.verses.selectedReference!
        let resultRows = third.workspace.verses.rows
        let beforeResult = live.projector.revision
        command("\r", modifiers: .command, code: 36, window: third.window!)
        let fourth = tabs.selected!
        try await settle(fourth.workspace)
        precondition(fourth.workspace.navigation.navigation.reference == selectedResult)
        precondition(live.projector.revision == beforeResult, "Command-Return prepares a search result without projecting")
        command("w", modifiers: .command, code: 13, window: fourth.window!)
        try await settle(third.workspace)
        precondition(third.workspace.searchMode == .wordSearch && third.workspace.draft == "john: light")
        precondition(third.workspace.verses.rows == resultRows && third.workspace.verses.selectedReference == selectedResult)
        third.window!.makeFirstResponder(third.workspace.verses.table)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: third.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        third.window!.sendEvent(enter)
        try await settle(third.workspace)
        precondition(live.projector.projectionOwner?.reference == selectedResult)
        let beforeClose = live.projector.revision
        command("w", modifiers: .command, code: 13, window: third.window!)
        try await settle(secondWorkspace)
        precondition(tabs.windows.count == 2 && live.projector.revision == beforeClose,
                     "Closing the originating tab must retain live output")
        precondition(secondWorkspace.statusLabel.stringValue.contains(selectedResult.verseQuery.title))
        secondWorkspace.closeProjector()
        try await settle(secondWorkspace)
        precondition(!live.windowOpened && live.projector.projectionOwner == nil)
        second.close()
        firstWindow.makeKeyAndOrderFront(nil)
        reviewLog("PASS native passage tabs: new/close/reorder, context and keyboard opening, independent draft/caret/scroll/search, shared saved activation and output, Blank/Preview/Stop, originating-tab close")
    }
    @MainActor static func checkTabCancellation(output: URL) async throws {
        let reader = ReviewBibleGate()
        let defaultsName = "ViewTheWord.TabCancellationReview"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let live = LiveProjectionController(library: BibleLibrary(preloadedURLs: []), defaults: defaults, sourceResolver: { _ in
            BibleSources(primary: output.appendingPathComponent("ENG_TEST.bible"), secondary: nil, revision: 1)
        })
        var opens = 0
        live.projectorWindowFactory = { _ in opens += 1; return nil }
        let tabs = PassageTabsController(liveProjection: live,
            history: HistoryStore(fileURL: output.appendingPathComponent("cancel-history.json")),
            bookmarks: BookmarkStore(fileURL: output.appendingPathComponent("cancel-bookmarks.json")), savesFrames: false,
            navigationFactory: { VerseTargetModel(readerFactory: { _ in reader }) })
        let first = tabs.open()
        first.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        first.workspace.changeSearchMode(.wordSearch)
        first.workspace.search.field.stringValue = "hope"
        first.workspace.search.field.sendAction(first.workspace.search.field.action, to: first.workspace.search.field.target)
        try await settle(first.workspace)
        let second = tabs.open(reference: VerseReference(book: "Romans", chapter: 8, verse: 1)!, after: first)
        try await settle(second.workspace)
        defer {
            for tab in tabs.windows { tab.close() }
            tabs.shutdown()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        command("\t", modifiers: [.control, .shift], code: 48, window: second.window!)
        try await waitUntil { first.window!.isKeyWindow }
        await reader.suspend(chapters: false, lookups: true)
        first.window!.makeFirstResponder(first.workspace.verses.table)
        sendKey("\r", code: 36, window: first.window!)
        try await waitUntil { await reader.hasLookup }
        second.workspace.render()
        precondition(second.workspace.stopButton.isEnabled && second.workspace.loadingLabel.stringValue == "Projecting…")
        command("\t", modifiers: .control, code: 48, window: first.window!)
        try await waitUntil { second.window!.isKeyWindow }
        second.workspace.focusSearch(nil)
        sendKey("\u{1b}", code: 53, window: second.window!)
        await reader.release()
        try await settle(second.workspace)
        precondition(live.projector.projectionOwner == nil && !live.isProjecting && opens == 0,
                     "Escape in another tab cancels a pending search-result projection")

        await reader.suspend(chapters: true, lookups: false)
        second.workspace.search.field.stringValue = "John 4:2"
        second.workspace.search.field.sendAction(second.workspace.search.field.action, to: second.workspace.search.field.target)
        try await waitUntil { await reader.hasChapter }
        command("\t", modifiers: [.control, .shift], code: 48, window: second.window!)
        try await waitUntil { first.window!.isKeyWindow }
        sendKey("\u{1b}", code: 53, window: first.window!)
        await reader.release()
        try await settle(second.workspace)
        precondition(second.workspace.navigation.navigation.reference == VerseReference(book: "John", chapter: 4, verse: 2))
        precondition(live.projector.projectionOwner == nil && !live.isProjecting && opens == 0,
                     "Escape stops pending output without canceling another tab's chapter load")
        reviewLog("PASS window-dispatched Escape: cross-tab pending search/verse cancellation, shared loading/Stop controls, late database completion cannot reopen output")
    }
    @MainActor static func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Native asynchronous event did not complete")
    }
    @MainActor static func sendKey(_ key: String, code: UInt16, window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        window.sendEvent(event)
    }
    @MainActor static func command(_ key: String, modifiers: NSEvent.ModifierFlags, code: UInt16, window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        precondition(NSApp.mainMenu!.performKeyEquivalent(with: event), "Menu key equivalent must route through the active window")
    }
    @MainActor static func invoke(_ title: String, in menu: NSMenu) {
        let item = menu.items.first { $0.title == title }!
        precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
    }
    @MainActor static func activateSaved(_ reference: VerseReference, in saved: NativeSidebarController, window: NSWindow) {
        let outline = saved.outline
        let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.reference == reference }!
        outline.scrollRowToVisible(row)
        window.contentView?.layoutSubtreeIfNeeded()
        click(outline, rect: outline.rect(ofRow: row), window: window)
    }
    @MainActor static func checkSavedActivation(_ workspace: MainWorkspaceController, window: NSWindow) async throws {
        let historyBefore = workspace.history.entries
        workspace.navigate(to: VerseReference(book: "John", chapter: 3, verse: 16)!, project: true, focusVerses: false)
        try await settle(workspace)
        for (saved, mode) in [(workspace.savedBookmarks, SearchMode.wordSearch), (workspace.savedHistory, .phraseSearch)] {
            workspace.changeSearchMode(mode)
            let outline = saved.outline
            let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.reference != nil }!
            let reference = (outline.item(atRow: row) as! SidebarNode).reference!
            for attempt in 0..<3 {
                if attempt == 1 {
                    workspace.closeProjector()
                    try await settle(workspace)
                    precondition(workspace.projector.projectionOwner == nil)
                } else if attempt == 2 {
                    let other = workspace.verses.rows.first { $0.reference != reference }!.reference
                    workspace.activateVerse(other)
                    try await settle(workspace)
                    precondition(workspace.projector.projectionOwner?.reference == other)
                }
                let revision = workspace.projector.revision
                outline.scrollRowToVisible(row)
                window.contentView?.layoutSubtreeIfNeeded()
                click(outline, rect: outline.rect(ofRow: row), window: window)
                try await settle(workspace)
                precondition(workspace.navigation.navigation.reference == reference, "Saved activation must load its reference")
                precondition(workspace.verses.selectedReference == reference, "Saved activation must select its verse row")
                precondition(workspace.projector.projectionOwner?.reference == reference, "Saved activation must also project on this click")
                precondition(workspace.projector.projectorViewData.title == reference.verseQuery.title)
                precondition(workspace.projector.projectorViewData.primaryText == workspace.verses.rows.first { $0.reference == reference }!.primaryText)
                precondition(workspace.projector.revision == revision + 1, "Each saved click must publish exactly once")
            }
            reviewLog("PASS \(outline.accessibilityLabel()!): first click projects, same-row click resumes and replaces projection")
        }
        precondition(workspace.history.entries == historyBefore, "Replaying saved references must not add history entries")
        workspace.closeProjector()
        try await settle(workspace)
        workspace.changeSearchMode(.verseReference)
    }
    @MainActor static func checkSavedPane(_ saved: NativeSidebarController, in column: NSView) -> CGFloat {
        let frame = saved.view.convert(saved.view.bounds, to: column)
        precondition(abs(frame.minX - column.bounds.minX) < 1 && abs(frame.width - column.bounds.width) < 1,
                     "Saved references must fill the resized pane and start at its leading edge")
        let outline = saved.outline
        precondition(abs(outline.frame.width - saved.scrollView.contentSize.width) < 1,
                     "Saved row selection must span the scrollable pane")
        precondition(outline.bounds.height > saved.scrollView.contentSize.height,
                     "Saved-reference fixtures must contain enough rows to exercise scrolling")
        let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.reference != nil }!
        let node = outline.item(atRow: row) as! SidebarNode
        saved.apply(saved.nodes, selectionID: node.id)
        outline.scrollRowToVisible(outline.numberOfRows - 1)
        outline.scrollRowToVisible(row)
        saved.view.layoutSubtreeIfNeeded()
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTableCellView
        let text = cell.textField!
        let textOrigin = text.convert(text.bounds, to: saved.view).minX
        reviewLog("PASS \(outline.accessibilityLabel()!): full-width scrolling rows, text x=\(textOrigin)")
        return textOrigin
    }
    @MainActor static func click(_ view: NSView, rect: NSRect, window: NSWindow) {
        let location = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
    }
    @MainActor static func settle(_ workspace: MainWorkspaceController) async throws {
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if !workspace.navigation.isLoading && !workspace.liveProjection.isProjecting { break }
        }
        workspace.render()
        try await Task.sleep(nanoseconds: 100_000_000)
        workspace.view.layoutSubtreeIfNeeded()
    }
    @MainActor static func checkNavigation(_ workspace: MainWorkspaceController, window: NSWindow) async throws {
        for book in ["Exodus", "Leviticus", "John", "Psalm"] {
            let bookRow = (0..<workspace.books.outline.numberOfRows).first {
                (workspace.books.outline.item(atRow: $0) as? SidebarNode)?.book == book
            }!
            workspace.books.outline.scrollRowToVisible(bookRow)
            window.contentView?.layoutSubtreeIfNeeded()
            click(workspace.books.outline, rect: workspace.books.outline.rect(ofRow: bookRow), window: window)
            precondition(workspace.browsedBook == book, "First book click must browse \(book)")
            try await settle(workspace)
            let item = workspace.chapters.collection.item(at: IndexPath(item: 2, section: 0))!
            click(item.view, rect: item.view.bounds, window: window)
            try await settle(workspace)
            let reference = VerseReference(book: book, chapter: 3, verse: 1)!
            precondition(workspace.navigation.navigation.reference == reference, "First chapter click must navigate to \(book) 3")
            precondition(workspace.chapters.selectedReference == reference)
            precondition(workspace.verses.rows.first?.reference == reference)
            precondition(window.firstResponder === workspace.chapters.collection)
            precondition(workspace.projector.projectionOwner == nil, "Browsing must not project")
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
            window.sendEvent(down)
            try await settle(workspace)
            precondition(workspace.navigation.navigation.reference == VerseReference(book: book, chapter: 3 + workspace.chapters.columnCount, verse: 1), "Down arrow moves to the chapter beneath it")
            reviewLog("PASS window-dispatched click: \(book) → 3 on the first click")
        }
        precondition(NSApp.sendAction(#selector(MainWorkspaceController.focusSearch(_:)), to: nil, from: nil))
        precondition(workspace.search.field.currentEditor() != nil, "Search command must reach the toolbar editor")
        precondition(NSApp.sendAction(#selector(MainWorkspaceController.focusSearch(_:)), to: nil, from: nil), "Search command must also work while editing in the toolbar")
        reviewLog("PASS native chapter grid arrows and toolbar search responder command")
    }

}

/// Deliberately returns pending work after Escape so the native responder check
/// verifies cancellation guards rather than a cooperative database implementation.
private actor ReviewBibleGate: BibleReading {
    private var suspendChapters = false
    private var suspendLookups = false
    private var chapterContinuation: CheckedContinuation<Void, Never>?
    private var lookupContinuation: CheckedContinuation<Void, Never>?
    var hasChapter: Bool { chapterContinuation != nil }
    var hasLookup: Bool { lookupContinuation != nil }
    func suspend(chapters: Bool, lookups: Bool) { suspendChapters = chapters; suspendLookups = lookups }
    func release() {
        chapterContinuation?.resume(); chapterContinuation = nil
        lookupContinuation?.resume(); lookupContinuation = nil
    }
    func chapter(_ reference: VerseReference) async throws -> [AVerse] {
        if suspendChapters { await withCheckedContinuation { chapterContinuation = $0 } }
        return (1...30).map { AVerse(reference: VerseReference(book: reference.book, chapter: reference.chapter, verse: $0)!, verse: "Hope and faith") }
    }
    func verses(_ references: [VerseReference]) async throws -> [AVerse] {
        if suspendLookups { await withCheckedContinuation { lookupContinuation = $0 } }
        return references.map { AVerse(reference: $0, verse: "Hope and faith") }
    }
    func search(_ request: TextSearchRequest, after: VerseCoordinate?, limit: Int) async throws -> [AVerse] {
        (1...3).map { AVerse(reference: VerseReference(book: "John", chapter: 3, verse: $0)!, verse: "Hope and faith") }
    }
}
