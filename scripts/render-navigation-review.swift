import AppKit

@main
struct NativeWorkspaceReview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await review(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }
    @MainActor static func review() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = root.appendingPathComponent("build/review/navigation", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ViewTheWord.NativeWorkspaceReview")!
        defaults.removePersistentDomain(forName: "ViewTheWord.NativeWorkspaceReview")
        defaults.set(17.0, forKey: AppDefaultsKey.verseRowFontSize)
        let sources = BibleSources(primary: root.appendingPathComponent("ViewTheWord/Resources/MAL_BSI.bible"),
                                   secondary: root.appendingPathComponent("ViewTheWord/Resources/ENG_UKJV.bible"), revision: 1)
        let workspace = MainWorkspaceController(history: HistoryStore(fileURL: output.appendingPathComponent("history.json")),
            bookmarks: BookmarkStore(fileURL: output.appendingPathComponent("bookmarks.json")), defaults: defaults,
            sourceResolver: { primaryOnly in BibleSources(primary: sources.primary, secondary: primaryOnly ? nil : sources.secondary, revision: 1) })
        // Exercise projection publication without sending fixture content to a display.
        workspace.projectorWindowFactory = { _ in nil }
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
        let controller = MainWindowController(workspace: workspace, savesFrame: false)
        let window = controller.window!
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        window.makeKey()
        precondition(NSApp.isRunning && NSApp.isActive && window.isKeyWindow, "Window-event checks require a running AppKit application")
        try await checkNavigation(workspace, window: window)
        try await checkSavedActivation(workspace, window: window)
        defer { window.close(); defaults.removePersistentDomain(forName: "ViewTheWord.NativeWorkspaceReview") }
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
            print("PASS \(name): \(workspace.chapters.columnCount) chapter columns, native toolbar, Psalm 119:53, bilingual text")
        }
        precondition(counts.count >= 2, "Chapter columns must adapt to pane width")
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
            print("PASS \(outline.accessibilityLabel()!): first click projects, same-row click resumes and replaces projection")
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
        print("PASS \(outline.accessibilityLabel()!): full-width scrolling rows, text x=\(textOrigin)")
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
            if !workspace.navigation.isLoading { break }
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
            print("PASS window-dispatched click: \(book) → 3 on the first click")
        }
        precondition(NSApp.sendAction(#selector(MainWorkspaceController.focusSearch(_:)), to: nil, from: nil))
        precondition(workspace.search.field.currentEditor() != nil, "Search command must reach the toolbar editor")
        precondition(NSApp.sendAction(#selector(MainWorkspaceController.focusSearch(_:)), to: nil, from: nil), "Search command must also work while editing in the toolbar")
        print("PASS native chapter grid arrows and toolbar search responder command")
    }

}
