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
        defaults.set(sources.primary.absoluteString, forKey: AppDefaultsKey.primaryBibleName)
        defaults.set(sources.secondary!.absoluteString, forKey: AppDefaultsKey.secondaryBibleName)
        let live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [sources.primary, sources.secondary!]), defaults: defaults)
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
                               ("Psalm", 23, 1), ("John", 3, 16), ("Romans", 8, 28), ("Esther", 8, 9)]
            .map { VerseReference(book: $0.0, chapter: $0.1, verse: $0.2)! }
        for reference in savedReferences {
            workspace.bookmarks.add(reference)
            workspace.history.append(reference.verseQuery.title)
        }
        let window = controller.window!
        positionFixtureWindow(window)
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
        defer { tabs.shutdown(); for tab in tabs.windows { tab.close() }; defaults.removePersistentDomain(forName: "ViewTheWord.NativeWorkspaceReview") }
        if CommandLine.arguments.contains("--passage-tabs-only") {
            try await checkPassageTabs(tabs, original: controller, output: output, outputCreations: { outputCreations })
            try await checkTabTranslations(tabs, original: controller, output: output)
            return
        }
        try await checkHistoryVerseReveal(workspace, window: window, output: output)
        if CommandLine.arguments.contains("--history-reveal-only") { return }
        try await checkDelayedSearchFocus(output: output)
        try await checkQueuedLibraryAlerts(output: output)
        try await checkSettingsImportLifecycle(output: output)
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { window.isKeyWindow }
        try await checkTestamentSwitch(workspace, window: window)
        try await checkNavigation(workspace, window: window)
        try await checkSavedActivation(workspace, window: window)
        try await checkBookmarkRemoval(workspace, window: window)
        try await checkPassageTabs(tabs, original: controller, output: output, outputCreations: { outputCreations })
        try await checkTabTranslations(tabs, original: controller, output: output)
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
            // Cache the sidebar itself; the outer floating glass surface omits
            // its child content when caching the complete window offscreen.
            let bookPane = workspace.books.view
            let bookBitmap = bookPane.bitmapImageRepForCachingDisplay(in: bookPane.bounds)!
            bookPane.cacheDisplay(in: bookPane.bounds, to: bookBitmap)
            try bookBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + "-books.png"))
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
        precondition(second.window!.tab.title == "Psalm 23:1 · BSI / UKJV")
        precondition(firstWindow.tab.title == "● Live · John 3:16 · BSI / UKJV")
        precondition(firstWindow.tabGroup?.windows.count == 2)
        precondition(second.workspace.navigation.navigation.reference == psalm)
        precondition(first.navigation.navigation.reference == john && first.verses.rows == rows)
        precondition(first.testamentControl.selectedSegment == 1 && second.workspace.testamentControl.selectedSegment == 0,
                     "Passage tabs must keep independent testament filters")
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
        precondition(first.testamentControl.selectedSegment == 1 && first.books.selectedNode?.book == "John",
                     "Switching tabs must restore its testament and book selection")
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
        precondition(third.window!.tab.title == "Romans 8:28 · BSI / UKJV" && live.projector.revision == beforeNewTab)
        activateSaved(romans, in: third.workspace.savedHistory, window: third.window!)
        try await settle(third.workspace)
        precondition(live.projector.projectionOwner?.reference == romans)
        precondition(first.history.entries == historyBefore, "Saved activations in all tabs remain history-neutral")
        precondition(NSApp.sendAction(#selector(MainWindowController.moveTabLeft(_:)), to: nil, from: nil))
        precondition(firstWindow.tabGroup?.windows == [firstWindow, third.window!, second.window!])
        precondition(NSApp.sendAction(#selector(MainWindowController.moveTabRight(_:)), to: nil, from: nil))
        precondition(firstWindow.tabGroup?.windows == [firstWindow, second.window!, third.window!])
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
    @MainActor static func checkTabTranslations(_ tabs: PassageTabsController, original: MainWindowController, output: URL) async throws {
        func choose(_ url: URL?, in picker: NSPopUpButton) {
            let index = picker.itemArray.firstIndex { ($0.representedObject as? String) == (url?.absoluteString ?? "") }!
            picker.selectItem(at: index)
            picker.sendAction(picker.action, to: picker.target)
        }
        let a = original.workspace
        let originalChoices = a.translations
        let live = tabs.liveProjection
        let john = VerseReference(book: "John", chapter: 3, verse: 16)!
        var choices = originalChoices
        choices.primary = originalChoices.secondary
        choices.secondary = originalChoices.primary
        choices.primaryOnly = true
        a.setTranslations(choices)
        try await settle(a)
        a.navigate(to: john, project: true, focusVerses: false)
        try await settle(a)
        let projected = live.projector.projectorViewData
        let revision = live.projector.revision
        let second = tabs.open(after: original)
        let b = second.workspace
        try await settle(b)
        precondition(b.translations == a.translations, "New tabs copy all translation choices, including Secondary None")
        precondition(!b.secondaryPicker.isHidden && b.secondaryPicker.selectedItem?.title == "None")
        precondition(second.window!.tab.title == "New Passage · UKJV")
        precondition(original.window!.tab.title == "● Live · John 3:16 · UKJV")
        precondition(live.source?.tabID == a.tabID, "Selecting a new tab cannot transfer live ownership")

        choose(originalChoices.primary, in: b.primaryPicker)
        choose(originalChoices.primary, in: b.secondaryPicker)
        try await settle(b); a.render()
        precondition(a.translations == choices && b.translations.primary == originalChoices.primary && !b.primaryOnly)
        precondition(live.projector.revision == revision && live.projector.projectorViewData == projected)
        precondition(b.sources.secondary == originalChoices.primary, "Choosing a secondary translation restores both texts")
        precondition(a.library.defaultTranslations(a.defaults) == b.translations, "Remember explicit picker choices for the next first passage")
        let third = tabs.open(after: second)
        try await settle(third.workspace)
        precondition(third.workspace.translations == b.translations && third.workspace.translations != a.translations)
        third.close()
        b.setTranslations(originalChoices)
        b.navigate(to: VerseReference(book: "Psalm", chapter: 23, verse: 1)!, project: true, focusVerses: false)
        try await settle(b); a.render()
        precondition(live.source?.tabID == b.tabID && original.window!.tab.attributedTitle == nil)
        precondition(second.window!.tab.title == "● Live · Psalm 23:1 · BSI / UKJV")
        a.toggleBlank(nil)
        try await settle(b)
        precondition(second.window!.tab.title == "● Blanked · Psalm 23:1 · BSI / UKJV")
        choose(nil, in: b.secondaryPicker)
        try await settle(b)
        precondition(live.projector.isBlanked && live.projector.projectorViewData.secondaryText == nil)
        precondition(!b.secondaryPicker.isHidden && b.secondaryPicker.selectedItem?.title == "None")
        precondition(a.library.defaultTranslations(a.defaults) == b.translations)
        precondition(second.window!.tab.title == "● Blanked · Psalm 23:1 · BSI")
        for (name, dark) in [("native-translation-tabs-live", false), ("native-translation-tabs-blanked-dark", true)] {
            a.toggleBlank(nil)
            original.window!.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            second.window!.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            // Capture the owning tab while a different tab has native selection.
            original.window!.makeKeyAndOrderFront(nil)
            try await settle(a); b.render()
            let frame = original.window!.contentView!.superview!
            frame.layoutSubtreeIfNeeded()
            let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        let beforeClose = live.projector.revision
        second.close()
        a.setTranslations(originalChoices)
        try await settle(a)
        precondition(live.source?.tabID == nil && live.projector.revision == beforeClose && live.projector.isBlanked)
        precondition(original.window!.tab.attributedTitle == nil)
        a.closeProjector()
        try await settle(a)
        reviewLog("PASS tab translations: copied choices, independent Primary/Secondary/None pickers, remembered choices, source-only live refresh, native Live/Blanked headings, closed-source output retained")
    }

    @MainActor static func checkTabCancellation(output: URL) async throws {
        let reader = ReviewBibleGate()
        let defaultsName = "ViewTheWord.TabCancellationReview"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        defaults.set(true, forKey: AppDefaultsKey.showOnlyPrimary)
        let live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [output.appendingPathComponent("ENG_TEST.bible")]), defaults: defaults)
        var opens = 0
        live.projectorWindowFactory = { _ in opens += 1; return nil }
        let tabs = PassageTabsController(liveProjection: live,
            history: HistoryStore(fileURL: output.appendingPathComponent("cancel-history.json")),
            bookmarks: BookmarkStore(fileURL: output.appendingPathComponent("cancel-bookmarks.json")), savesFrames: false,
            navigationFactory: { VerseTargetModel(readerFactory: { _ in reader }) })
        let first = tabs.open()
        positionFixtureWindow(first.window!)
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
    @MainActor static func waitUntil(_ predicate: () async -> Bool,
                                     file: StaticString = #file, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Native asynchronous event did not complete", file: file, line: line)
    }
    @MainActor static func checkDelayedSearchFocus(output: URL) async throws {
        let reader = ReviewBibleGate()
        await reader.suspend(chapters: false, lookups: false, searches: true)
        let defaultsName = "ViewTheWord.DelayedSearchReview"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(true, forKey: AppDefaultsKey.showOnlyPrimary)
        let live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [output.appendingPathComponent("ENG_TEST.bible")]), defaults: defaults)
        live.projectorWindowFactory = { _ in nil }
        let tabs = PassageTabsController(liveProjection: live,
            history: HistoryStore(fileURL: output.appendingPathComponent("focus-history.json")),
            bookmarks: BookmarkStore(fileURL: output.appendingPathComponent("focus-bookmarks.json")), savesFrames: false,
            navigationFactory: { VerseTargetModel(readerFactory: { _ in reader }) })
        let controller = tabs.open()
        let subject = controller.workspace
        let window = controller.window!
        positionFixtureWindow(window)
        try await waitUntil { NSApp.isActive && window.isKeyWindow }
        defer {
            for tab in tabs.windows { tab.close() }
            tabs.shutdown()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        for mode in [SearchMode.wordSearch, .phraseSearch] {
            for action in ["unchanged", "edit", "edit back", "move focus", "leave and return"] {
                subject.changeSearchMode(mode)
                subject.focusSearch(nil)
                var editor = subject.search.field.currentEditor() as! NSTextView
                editor.selectAll(nil)
                editor.insertText("hope", replacementRange: editor.selectedRange())
                sendKey("\r", code: 36, window: window)
                try await waitUntil { await reader.hasSearch }
                switch action {
                case "edit", "edit back":
                    // Return can end field editing. Command-L starts the user's
                    // next draft through the real toolbar responder command.
                    command("l", modifiers: .command, code: 37, window: window)
                    editor = subject.search.field.currentEditor() as! NSTextView
                    editor.selectAll(nil)
                    editor.insertText("faith", replacementRange: editor.selectedRange())
                    if action == "edit back" {
                        editor.selectAll(nil)
                        editor.insertText("hope", replacementRange: editor.selectedRange())
                    }
                case "move focus", "leave and return":
                    subject.focus(.books)
                    if action == "leave and return" {
                        subject.focusSearch(nil)
                        editor = subject.search.field.currentEditor() as! NSTextView
                    }
                default: break
                }
                await reader.release()
                try await settle(subject)
                precondition(subject.verses.rows.count == 3)
                switch action {
                case "unchanged":
                    precondition(window.firstResponder === subject.verses.table, "An unchanged \(mode) submission focuses results")
                case "move focus":
                    precondition(window.firstResponder === subject.books.outline, "A pending search must respect newer focus")
                default:
                    precondition(window.firstResponder === editor, "\(mode) completion must preserve the editor after \(action)")
                    precondition(subject.draft == (action == "edit" ? "faith" : "hope"))
                }
            }
        }
        await reader.setReadFailure(true)
        for mode in SearchMode.allCases {
            subject.changeSearchMode(mode)
            subject.focusSearch(nil)
            let editor = subject.search.field.currentEditor() as! NSTextView
            editor.selectAll(nil)
            let draft = mode == .verseReference ? "John 3:16" : "hope"
            editor.insertText(draft, replacementRange: editor.selectedRange())
            await reader.suspend(chapters: true, lookups: false, searches: true)
            sendKey("\r", code: 36, window: window)
            try await waitUntil {
                if mode == .verseReference { return await reader.hasChapter }
                return await reader.hasSearch
            }
            await reader.release()
            try await settle(subject)
            precondition(subject.navigation.message != nil && subject.draft == draft)
            precondition(window.firstResponder !== subject.verses.table, "Failed submissions must not focus stale rows")
            precondition(subject.history.entries.isEmpty && live.projector.projectionOwner == nil,
                         "Failed submissions must not record history or publish")
        }
        reviewLog("PASS delayed Words/Phrase search: Return focuses results only without newer edits or focus changes")
        reviewLog("PASS failed Ref/Words/Phrase submissions: visible errors, preserved draft/focus, no history or publication")
    }

    @MainActor static func checkQueuedLibraryAlerts(output: URL) async throws {
        let library = BibleLibrary(preloadedURLs: [], importer: { url, _, replace in
            if url.lastPathComponent.contains("EXISTING") && !replace {
                throw BibleImportError.bibleAlreadyExists(url.lastPathComponent)
            }
            if url.lastPathComponent.contains("INVALID") { throw CocoaError(.fileReadCorruptFile) }
            return url
        })
        let defaultsName = "ViewTheWord.QueuedImportsReview"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let live = LiveProjectionController(library: library, defaults: defaults)
        live.projectorWindowFactory = { _ in nil }
        let tabs = PassageTabsController(liveProjection: live,
            history: HistoryStore(fileURL: output.appendingPathComponent("import-history.json")),
            bookmarks: BookmarkStore(fileURL: output.appendingPathComponent("import-bookmarks.json")), savesFrames: false)
        let inactive = tabs.open()
        let active = tabs.open(after: inactive)
        let window = active.window!
        positionFixtureWindow(window)
        try await waitUntil { window.isKeyWindow }
        defer {
            for tab in tabs.windows { tab.close() }
            tabs.shutdown()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        for name in ["FIRST", "EXISTINGCANCEL", "EXISTINGREPLACE", "INVALID", "LAST"] {
            library.importFile(output.appendingPathComponent("ENG_\(name).bible"), presenter: .main)
        }
        for (name, response) in [("FIRST", NSApplication.ModalResponse.alertFirstButtonReturn),
                                 ("EXISTINGCANCEL", .alertSecondButtonReturn), ("EXISTINGREPLACE", .alertFirstButtonReturn),
                                 ("EXISTINGREPLACE", .alertFirstButtonReturn), ("INVALID", .alertFirstButtonReturn),
                                 ("LAST", .alertFirstButtonReturn)] {
            try await waitUntil { window.attachedSheet != nil }
            let alert = library.alert(for: .main)!
            precondition(alert.message.contains(name), "Each queued result must retain its file identity")
            precondition(inactive.window!.attachedSheet == nil, "Only the active tab may present a library alert")
            window.endSheet(window.attachedSheet!, returnCode: response)
            try await waitUntil { library.alert(for: .main)?.id != alert.id }
        }
        precondition(!library.isImporting && library.alerts.isEmpty)
        precondition(Set(library.urls.map(\.lastPathComponent)) == ["ENG_FIRST.bible", "ENG_EXISTINGREPLACE.bible", "ENG_LAST.bible"])
        reviewLog("PASS queued import sheets: all files, explicit Replace/Cancel, failures continue, one active-tab presenter")
    }
    @MainActor static func checkSettingsImportLifecycle(output: URL) async throws {
        let importer = ReviewImportGate()
        let library = BibleLibrary(preloadedURLs: [], importer: { url, _, replace in
            try await importer.run(url, replace: replace)
        })
        let settings = SettingsWindowController(library: library)
        let window = settings.window!
        positionFixtureWindow(window)
        defer { settings.close() }
        for response in [NSApplication.ModalResponse.abort, .alertFirstButtonReturn] {
            settings.showWindow(nil)
            try await waitUntil { window.isKeyWindow }
            let existing = output.appendingPathComponent("ENG_SETTINGS.bible")
            let later = output.appendingPathComponent("ENG_LATER.bible")
            library.importFile(existing, presenter: .settings)
            library.importFile(later, presenter: .main)
            try await waitUntil { await importer.waiting }
            await importer.finish(.failure(BibleImportError.bibleAlreadyExists(existing.lastPathComponent)))
            // Settings opens on Display. Its import decision must still appear.
            try await waitUntil { window.attachedSheet != nil }
            let prompt = library.alert(for: .settings)!
            window.endSheet(window.attachedSheet!, returnCode: response)
            try await waitUntil { await importer.waiting }
            let replacing = await importer.isReplacing
            if response == .alertFirstButtonReturn {
                precondition(replacing, "Only explicit Replace retries the existing file")
                await importer.finish(.success(existing))
                try await waitUntil { await importer.waiting }
            } else { precondition(!replacing, "A non-button dismissal cancels replacement") }
            await importer.finish(.success(later))
            try await waitUntil { !library.isImporting }
            library.completeAlert(prompt.id, replaceExisting: true)
            if response == .alertFirstButtonReturn {
                try await waitUntil { window.attachedSheet != nil }
                let notice = library.alert(for: .settings)!
                window.endSheet(window.attachedSheet!, returnCode: .alertFirstButtonReturn)
                try await waitUntil { library.alert(for: .settings)?.id != notice.id }
            }
            while let alert = library.alerts.first { library.completeAlert(alert.id) }
        }

        // Closing while validation is pending must release later Finder files
        // even if Settings is reopened before that validation finishes.
        let existing = output.appendingPathComponent("ENG_CLOSEDSETTINGS.bible")
        let later = output.appendingPathComponent("ENG_AFTERCLOSE.bible")
        library.importFile(existing, presenter: .settings)
        library.importFile(later, presenter: .main)
        try await waitUntil { await importer.waiting }
        settings.close()
        settings.showWindow(nil)
        await importer.finish(.failure(BibleImportError.bibleAlreadyExists(existing.lastPathComponent)))
        try await waitUntil { await importer.waiting }
        let replacingAfterClose = await importer.isReplacing
        precondition(!replacingAfterClose)
        await importer.finish(.success(later))
        try await waitUntil { !library.isImporting && library.urls.contains(later) }
        precondition(!library.alerts.contains { if case .replacement = $0.content { return true }; return false })
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
        reviewLog("PASS Settings import sheets: Display tab presentation, non-button cancellation, explicit replacement, closing during validation resumes later files")
    }

    @MainActor static func sendKey(_ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
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
                precondition(workspace.books.selectedNode?.book == reference.book,
                             "Saved activation must reveal its book in the correct testament")
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
    @MainActor static func checkHistoryVerseReveal(_ workspace: MainWorkspaceController, window: NSWindow, output: URL) async throws {
        let origin = VerseReference(book: "Psalm", chapter: 117, verse: 2)!
        let target = VerseReference(book: "Esther", chapter: 8, verse: 9)!
        let historyBefore = workspace.history.entries
        for (name, width, height, fontSize, primaryOnly) in [
            ("history-esther-bilingual", 1200.0, 800.0, 17.0, false),
            ("history-esther-compact", 950.0, 600.0, 20.0, false),
            ("history-esther-primary", 1200.0, 800.0, 17.0, true)
        ] {
            window.setContentSize(NSSize(width: width, height: height))
            workspace.defaults.set(fontSize, forKey: AppDefaultsKey.verseRowFontSize)
            workspace.setSecondaryTranslation(primaryOnly ? nil : workspace.translations.secondary)
            workspace.render()
            try await settle(workspace)
            // Repeat to cover a click on the already-selected History entry.
            for _ in 0..<2 {
                workspace.navigate(to: origin, focusVerses: false)
                try await settle(workspace)
                precondition(workspace.verses.rows.count == 2)
                activateSaved(target, in: workspace.savedHistory, window: window)
                try await settle(workspace)
                precondition(workspace.verses.selectedReference == target)
                let table = workspace.verses.table
                let row = table.rect(ofRow: table.selectedRow)
                let viewport = table.visibleRect
                let frame = workspace.verses.scrollView
                let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
                if row.height <= viewport.height {
                    precondition(abs(row.midY - viewport.midY) <= 1,
                                 "History must center the measured verse: row=\(row), viewport=\(viewport)")
                } else {
                    precondition(abs(row.minY - viewport.minY) <= 1,
                                 "A verse taller than the viewport must start visibly at the top: row=\(row), viewport=\(viewport)")
                }
            }
            reviewLog("PASS \(name): Psalm 117:2 → History Esther 8:9, measured verse reveal and same-row reactivation")
        }
        precondition(workspace.history.entries == historyBefore)
        workspace.setSecondaryTranslation(workspace.translations.secondary)
        workspace.closeProjector()
        try await settle(workspace)
    }
    @MainActor static func checkBookmarkRemoval(_ workspace: MainWorkspaceController, window: NSWindow) async throws {
        let saved = workspace.savedBookmarks
        let original = workspace.bookmarks.entries
        let first = saved.nodes[0]
        let second = saved.nodes[1]
        workspace.navigate(to: VerseReference(book: "John", chapter: 3, verse: 16)!, project: true, focusVerses: false)
        try await settle(workspace)
        let referenceBefore = workspace.navigation.navigation.reference
        let revisionBefore = workspace.projector.revision
        let historyBefore = workspace.history.entries
        for node in [second, first] {
            saved.apply(saved.nodes, selectionID: first.id)
            let row = saved.outline.row(forItem: saved.nodes.first { $0.id == node.id }!)
            saved.outline.scrollRowToVisible(row)
            window.contentView?.layoutSubtreeIfNeeded()
            let cell = saved.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as! NSTableCellView
            let button = cell.subviews.compactMap { $0 as? NSButton }.first!
            click(button, rect: button.bounds, window: window)
            try await settle(workspace)
            precondition(workspace.bookmarks.entries == original.filter { $0.reference != node.reference },
                         "Minus must remove only the clicked bookmark")
            precondition(saved.selectedNode?.id == (node.id == first.id ? nil : first.id),
                         "Removing a bookmark must not select another reference")
            precondition(workspace.navigation.navigation.reference == referenceBefore && workspace.projector.revision == revisionBefore,
                         "Removing selected or unselected bookmarks must not navigate or publish")
            precondition(workspace.history.entries == historyBefore)
            command("z", modifiers: .command, code: 6, window: window)
            try await settle(workspace)
            precondition(workspace.bookmarks.entries == original, "Command-Z must restore the removed bookmark")
            precondition(workspace.projector.revision == revisionBefore, "Bookmark Undo must leave live output unchanged")
        }
        workspace.closeProjector()
        try await settle(workspace)
        reviewLog("PASS bookmark minus buttons: selected and unselected removal, stable navigation/output, Command-Z restoration")
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
    @MainActor static func positionFixtureWindow(_ window: NSWindow) {
        if CommandLine.arguments.contains("--onscreen") { window.center() }
        else { window.setFrameOrigin(NSPoint(x: -10000, y: -10000)) }
    }

    @MainActor static func settle(_ workspace: MainWorkspaceController) async throws {
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            if !workspace.navigation.isLoading && !workspace.liveProjection.isProjecting { break }
        }
        workspace.render()
        try await Task.sleep(nanoseconds: 100_000_000)
        workspace.view.layoutSubtreeIfNeeded()
        try await waitUntil { !workspace.verses.isRevealingSelection }
        workspace.view.layoutSubtreeIfNeeded()
    }
    @MainActor static func selectTestament(_ segment: Int, workspace: MainWorkspaceController, window: NSWindow) async throws {
        let control = workspace.testamentControl
        guard control.selectedSegment != segment else { return }
        let width = control.bounds.width / 2
        click(control, rect: NSRect(x: CGFloat(segment) * width, y: 0, width: width, height: control.bounds.height), window: window)
        try await settle(workspace)
        precondition(control.selectedSegment == segment, "One segment click must switch testaments")
    }
    @MainActor static func checkTestamentSwitch(_ workspace: MainWorkspaceController, window: NSWindow) async throws {
        let control = workspace.testamentControl
        let outline = workspace.books.outline
        precondition(control.selectedSegment == 0 && outline.numberOfRows == 39)
        precondition(workspace.books.nodes.first?.book == "Genesis" && workspace.books.nodes.last?.book == "Malachi")
        let frame = control.convert(control.bounds, to: nil)
        outline.scrollRowToVisible(38)
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(workspace.books.scrollView.contentView.bounds.minY > 0, "Book fixture must exercise scrolling")
        precondition(control.convert(control.bounds, to: nil) == frame, "Testament control must stay pinned while books scroll")

        let john = VerseReference(book: "John", chapter: 3, verse: 16)!
        workspace.navigate(to: john, project: true, focusVerses: false)
        try await settle(workspace)
        precondition(control.selectedSegment == 1 && outline.numberOfRows == 27)
        precondition(workspace.books.nodes.first?.book == "Matthew" && workspace.books.nodes.last?.book == "Revelation")
        precondition(workspace.books.selectedNode?.book == "John", "Reference navigation must reveal the correct testament")
        let revision = workspace.projector.revision
        let history = workspace.history.entries
        try await selectTestament(0, workspace: workspace, window: window)
        precondition(outline.numberOfRows == 39 && outline.selectedRow == -1)
        precondition(outline.rows(in: outline.visibleRect).contains(0), "Switching to an unselected testament starts at its first book")
        precondition(workspace.navigation.navigation.reference == john && workspace.browsedBook == "John")
        precondition(workspace.projector.revision == revision && workspace.history.entries == history,
                     "Filtering books must preserve the passage, live output, and history")
        workspace.focusSearch(nil)
        let responder = window.firstResponder
        workspace.render()
        precondition(control.selectedSegment == 0 && window.firstResponder === responder,
                     "Snapshot refresh must preserve the chosen filter and keyboard focus")
        try await selectTestament(1, workspace: workspace, window: window)
        precondition(workspace.books.selectedNode?.book == "John")
        workspace.focusSearch(nil)
        let editor = window.firstResponder
        workspace.navigate(to: VerseReference(book: "Psalm", chapter: 23, verse: 1)!, focusVerses: false)
        try await settle(workspace)
        precondition(control.selectedSegment == 0 && workspace.books.selectedNode?.book == "Psalm")
        precondition(window.firstResponder === editor && workspace.projector.revision == revision,
                     "Automatic testament reveal must not steal focus or change live output")
        workspace.closeProjector()
        try await settle(workspace)
        reviewLog("PASS testament switch: pinned control, 39/27 books, silent filtering, automatic reference reveal, stable focus/output")
    }
    @MainActor static func checkNavigation(_ workspace: MainWorkspaceController, window: NSWindow) async throws {
        let activate = workspace.chapters.onActivate
        var chapterActivations = 0
        workspace.chapters.onActivate = { reference in chapterActivations += 1; activate(reference) }
        defer { workspace.chapters.onActivate = activate }
        for (book, firstKey, code) in [("Exodus", "\u{F703}", UInt16(124)), ("Leviticus", "\u{F701}", 125),
                                       ("John", "\u{F702}", 123), ("Psalm", "\u{F700}", 126),
                                       ("Luke", "\r", 36), ("Romans", " ", 49)] {
            try await selectTestament(["John", "Luke", "Romans"].contains(book) ? 1 : 0, workspace: workspace, window: window)
            let bookRow = (0..<workspace.books.outline.numberOfRows).first {
                (workspace.books.outline.item(atRow: $0) as? SidebarNode)?.book == book
            }!
            workspace.books.outline.scrollRowToVisible(bookRow)
            window.contentView?.layoutSubtreeIfNeeded()
            click(workspace.books.outline, rect: workspace.books.outline.rect(ofRow: bookRow), window: window)
            precondition(workspace.browsedBook == book, "First book click must browse \(book)")
            try await settle(workspace)
            let navigationBeforeTab = workspace.navigation.navigation.reference
            precondition(workspace.chapters.collection.selectionIndexPaths.isEmpty)
            sendKey("\t", code: 48, window: window)
            precondition(window.firstResponder === workspace.chapters.collection, "Tab from books must reach chapters")
            try await settle(workspace)
            precondition(workspace.navigation.navigation.reference == navigationBeforeTab,
                         "Tab only moves focus; it must not load a chapter")
            sendKey(firstKey, code: code, window: window)
            try await settle(workspace)
            precondition(workspace.navigation.navigation.reference == VerseReference(book: book, chapter: 1, verse: 1),
                         "The first chapter key after book → Tab must select and load chapter 1")
            precondition(workspace.chapters.collection.selectionIndexPaths == [IndexPath(item: 0, section: 0)])
            sendKey("\u{F703}", code: 124, window: window)
            try await settle(workspace)
            precondition(workspace.navigation.navigation.reference == VerseReference(book: book, chapter: 2, verse: 1),
                         "Subsequent arrows use native spatial chapter navigation")
            sendKey("\u{19}", code: 48, modifiers: .shift, window: window)
            precondition(window.firstResponder === workspace.books.outline, "Shift-Tab returns from chapters to books")
            sendKey("\t", code: 48, window: window)
            precondition(window.firstResponder === workspace.chapters.collection)
            let item = workspace.chapters.collection.item(at: IndexPath(item: 2, section: 0))!
            let beforeClick = chapterActivations
            click(item.view, rect: item.view.bounds, window: window)
            try await settle(workspace)
            let reference = VerseReference(book: book, chapter: 3, verse: 1)!
            precondition(workspace.navigation.navigation.reference == reference, "First chapter click must navigate to \(book) 3")
            precondition(workspace.chapters.selectedReference == reference)
            precondition(chapterActivations == beforeClick + 1, "Each chapter click emits one navigation intent")
            precondition((item.view as! NSButton).state == .on)
            click(item.view, rect: item.view.bounds, window: window)
            try await settle(workspace)
            precondition(chapterActivations == beforeClick + 2, "An already-selected chapter also emits one intent")
            precondition((item.view as! NSButton).state == .on, "Re-clicking the selected chapter must keep its highlight")
            precondition(workspace.verses.rows.first?.reference == reference)
            precondition(window.firstResponder === workspace.chapters.collection)
            precondition(workspace.projector.projectionOwner == nil, "Browsing must not project")
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)!
            window.sendEvent(down)
            try await settle(workspace)
            precondition(workspace.navigation.navigation.reference == VerseReference(book: book, chapter: 3 + workspace.chapters.columnCount, verse: 1), "Down arrow moves to the chapter beneath it")
            reviewLog("PASS \(book): book → Tab → chapter arrows, Shift-Tab return, chapter 3 on the first click")
        }
        window.makeFirstResponder(workspace.verses.table)
        sendKey("\t", code: 48, window: window)
        precondition(workspace.search.field.currentEditor() === window.firstResponder,
                     "Tab must leave the verse table and reach the toolbar search")
        sendKey("\u{19}", code: 48, modifiers: .shift, window: window)
        precondition(window.firstResponder === workspace.verses.table, "Shift-Tab from search returns to verses")
        sendKey("\u{19}", code: 48, modifiers: .shift, window: window)
        precondition(window.firstResponder !== workspace.verses.table, "Shift-Tab must also leave the verse table")
        precondition(NSApp.sendAction(#selector(MainWorkspaceController.focusSearch(_:)), to: nil, from: nil))
        precondition(workspace.search.field.currentEditor() != nil, "Search command must reach the toolbar editor")
        precondition(NSApp.sendAction(#selector(MainWorkspaceController.focusSearch(_:)), to: nil, from: nil), "Search command must also work while editing in the toolbar")
        reviewLog("PASS native chapter grid arrows and toolbar search responder command")
    }

}

private actor ReviewImportGate {
    private var pending: CheckedContinuation<URL, Error>?
    private(set) var isReplacing = false
    var waiting: Bool { pending != nil }
    func run(_ url: URL, replace: Bool) async throws -> URL {
        precondition(pending == nil)
        isReplacing = replace
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ result: Result<URL, Error>) {
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }
}

/// Deliberately returns pending work after Escape so the native responder check
/// verifies cancellation guards rather than a cooperative database implementation.
private actor ReviewBibleGate: BibleReading {
    private var readFailure = false
    private var suspendChapters = false
    private var suspendLookups = false
    private var suspendSearches = false
    private var chapterContinuation: CheckedContinuation<Void, Never>?
    private var lookupContinuation: CheckedContinuation<Void, Never>?
    private var searchContinuation: CheckedContinuation<Void, Never>?
    var hasChapter: Bool { chapterContinuation != nil }
    var hasLookup: Bool { lookupContinuation != nil }
    var hasSearch: Bool { searchContinuation != nil }
    func setReadFailure(_ value: Bool) { readFailure = value }
    func suspend(chapters: Bool, lookups: Bool, searches: Bool = false) {
        suspendChapters = chapters; suspendLookups = lookups; suspendSearches = searches
    }
    func release() {
        chapterContinuation?.resume(); chapterContinuation = nil
        lookupContinuation?.resume(); lookupContinuation = nil
        searchContinuation?.resume(); searchContinuation = nil
    }
    func chapter(_ reference: VerseReference) async throws -> [AVerse] {
        if suspendChapters { await withCheckedContinuation { chapterContinuation = $0 } }
        if readFailure { throw CocoaError(.fileReadCorruptFile) }
        return (1...30).map { AVerse(reference: VerseReference(book: reference.book, chapter: reference.chapter, verse: $0)!, verse: "Hope and faith") }
    }
    func verses(_ references: [VerseReference]) async throws -> [AVerse] {
        if suspendLookups { await withCheckedContinuation { lookupContinuation = $0 } }
        if readFailure { throw CocoaError(.fileReadCorruptFile) }
        return references.map { AVerse(reference: $0, verse: "Hope and faith") }
    }
    func search(_ request: TextSearchRequest, after: VerseCoordinate?, limit: Int) async throws -> [AVerse] {
        if suspendSearches { await withCheckedContinuation { searchContinuation = $0 } }
        if readFailure { throw CocoaError(.fileReadCorruptFile) }
        return (1...3).map { AVerse(reference: VerseReference(book: "John", chapter: 3, verse: $0)!, verse: "Hope and faith") }
    }
}
