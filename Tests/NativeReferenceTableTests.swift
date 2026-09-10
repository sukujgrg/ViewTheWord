import AppKit
import XCTest
@testable import ViewTheWordCore

@MainActor
final class NativeReferenceTableTests: XCTestCase {
    private func row(_ verse: Int, book: String = "Psalm", chapter: Int = 1) -> NativeReferenceRow {
        let reference = VerseReference(book: book, chapter: chapter, verse: verse)!
        return NativeReferenceRow(reference: reference, primaryText: "\(reference.verseQuery.title) text",
                                  primaryCopy: "\(reference.verseQuery.title) copy")
    }

    private func controller() -> NativeReferenceTableController {
        _ = NSApplication.shared
        let controller = NativeReferenceTableController()
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        controller.table.frame = controller.scrollView.bounds
        controller.table.tableColumns[0].width = 700
        return controller
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) -> NSEvent {
        let characters: [UInt16: String] = [
            123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}",
            116: "\u{F72C}", 121: "\u{F72D}", 115: "\u{F729}", 119: "\u{F72B}",
            36: "\r", 76: "\u{3}", 49: " ", 53: "\u{1B}"
        ]
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                               windowNumber: 0, context: nil, characters: characters[code] ?? "",
                               charactersIgnoringModifiers: characters[code] ?? "",
                               isARepeat: repeatKey, keyCode: code)!
    }

    func testSnapshotsChangeRowsAndSelectionWithoutActivating() {
        let subject = controller()
        var activations: [VerseReference] = []
        subject.onActivate = { activations.append($0) }
        let first = [row(1), row(2), row(3)]
        subject.apply(rows: first, selection: first[1].reference, style: .verses(fontSize: 17, dual: false))
        XCTAssertEqual(subject.table.selectedRow, 1)
        let next = [row(1, chapter: 2), row(2, chapter: 2)]
        subject.apply(rows: next, selection: next[0].reference, style: .verses(fontSize: 17, dual: false))
        XCTAssertEqual(subject.selectedReference, next[0].reference)
        let otherBook = [row(1, book: "1 Peter", chapter: 2)]
        subject.apply(rows: otherBook, selection: otherBook[0].reference, style: .verses(fontSize: 17, dual: false))
        let cell = subject.tableView(subject.table, viewFor: subject.table.tableColumns[0], row: 0)!
        XCTAssertTrue(cell.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains("1 Peter 2:1 text"))
        XCTAssertEqual(subject.selectedReference, otherBook[0].reference)
        XCTAssertTrue(activations.isEmpty)
    }

    func testArrowRepeatsAndJumpsActivateEachSelectionOnce() {
        let subject = controller()
        let rows = (1...30).map { row($0) }
        var activations: [Int] = []
        subject.onActivate = { activations.append($0.verse) }
        subject.apply(rows: rows, selection: rows[0].reference, style: .verses(fontSize: 17, dual: false))
        subject.table.keyDown(with: key(125))
        subject.table.keyDown(with: key(125, repeatKey: true))
        subject.table.keyDown(with: key(125, modifiers: .command))
        subject.table.keyDown(with: key(121))
        subject.table.keyDown(with: key(119))
        subject.table.keyDown(with: key(125)) // End boundary doesn't activate again.
        subject.table.keyDown(with: key(115))
        subject.table.keyDown(with: key(126))
        XCTAssertEqual(activations, [2, 3, 8, 18, 30, 1])
        XCTAssertEqual(subject.selectedReference, rows[0].reference)
    }

    func testNavigationUsesActualVerseNumbersAndDropsMissingSelection() {
        let subject = controller()
        let rows = [row(13, book: "3 John"), row(15, book: "3 John")]
        var activated: VerseReference?
        subject.onActivate = { activated = $0 }
        subject.apply(rows: rows, selection: rows[0].reference, style: .verses(fontSize: 17, dual: true))
        subject.table.keyDown(with: key(125))
        XCTAssertEqual(activated?.verse, 15)
        subject.apply(rows: [rows[0]], selection: rows[0].reference, style: .verses(fontSize: 17, dual: false))
        XCTAssertEqual(subject.selectedReference?.verse, 13)
        subject.apply(rows: [], selection: rows[0].reference, style: .verses(fontSize: 17, dual: false))
        XCTAssertNil(subject.selectedReference)
        subject.table.keyDown(with: key(119))
        XCTAssertNil(subject.selectedReference)
    }

    func testChapterShortcutToggleEscapeAndFocusEmitSeparateIntents() {
        let subject = controller()
        let item = row(2)
        var steps: [Int] = [], focus: [Int] = [], toggles: [VerseReference] = []
        var stops = 0, activations = 0
        subject.onActivate = { _ in activations += 1 }
        subject.onChapterStep = { steps.append($0) }
        subject.onMoveFocus = { focus.append($0) }
        subject.onToggle = { toggles.append($0) }
        subject.onCancel = { stops += 1 }
        subject.apply(rows: [item], selection: item.reference, style: .verses(fontSize: 17, dual: false))
        subject.table.keyDown(with: key(125, modifiers: .option))
        subject.table.keyDown(with: key(126, modifiers: .option))
        subject.table.keyDown(with: key(49))
        subject.table.keyDown(with: key(53))
        subject.table.keyDown(with: key(123))
        subject.table.keyDown(with: key(124))
        XCTAssertEqual(steps, [1, -1])
        XCTAssertEqual(toggles, [item.reference])
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(focus, [-1, 1])
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(subject.selectedReference, item.reference)
    }

    func testChapterKeyboardSelectionAndExplicitReactivation() {
        let subject = controller()
        let rows = (1...3).map { row(1, chapter: $0) }
        var chapters: [Int] = []
        subject.onActivate = { chapters.append($0.chapter) }
        subject.apply(rows: rows, selection: rows[0].reference, style: .chapters)
        subject.table.keyDown(with: key(125))
        subject.table.keyDown(with: key(36))
        subject.activateSelected() // Same row click follows this explicit path.
        subject.apply(rows: rows, selection: rows[1].reference, style: .chapters)
        XCTAssertEqual(chapters, [2, 2, 2])
    }

    func testLoadingKeepsSelectionAndAllowsCancelWithoutActivating() {
        let subject = controller()
        let rows = [row(1), row(2)]
        var activations = 0, stops = 0
        subject.onActivate = { _ in activations += 1 }
        subject.onCancel = { stops += 1 }
        subject.apply(rows: rows, selection: rows[0].reference, style: .verses(fontSize: 17, dual: false), enabled: false)
        subject.table.keyDown(with: key(125))
        subject.table.keyDown(with: key(119))
        subject.table.keyDown(with: key(36))
        subject.table.keyDown(with: key(53))
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(subject.selectedReference, rows[0].reference)
        XCTAssertFalse(subject.selectionShouldChange(in: subject.table))
    }

    func testWrappingRecalculatesForWidthFontAndSecondaryText() async throws {
        let subject = controller()
        let window = mountedWindow(subject)
        defer { window.close() }
        var item = row(1)
        item.secondaryText = String(repeating: "ദൈവം സ്നേഹമാകുന്നു. ", count: 25)
        subject.apply(rows: [item], selection: item.reference, style: .verses(fontSize: 17, dual: true))
        try await settle(subject)
        let wide = subject.table.rect(ofRow: 0).height
        window.setContentSize(NSSize(width: 350, height: 400))
        try await settle(subject)
        let narrow = subject.table.rect(ofRow: 0).height
        XCTAssertEqual(subject.table.bounds.width, subject.scrollView.contentSize.width, accuracy: 1)
        XCTAssertGreaterThan(narrow, wide)
        subject.apply(rows: [item], selection: item.reference, style: .verses(fontSize: 25, dual: true))
        try await settle(subject)
        let larger = subject.table.rect(ofRow: 0).height
        XCTAssertGreaterThan(larger, narrow)
        subject.apply(rows: [item], selection: item.reference, style: .verses(fontSize: 25, dual: false))
        try await settle(subject)
        // Hidden secondary text must not inflate the primary-only row.
        let primaryHeight = subject.table.rect(ofRow: 0).height
        XCTAssertLessThan(primaryHeight, larger)
        item.secondaryText = nil
        subject.apply(rows: [item], selection: item.reference, style: .verses(fontSize: 25, dual: false))
        try await settle(subject)
        XCTAssertEqual(subject.table.rect(ofRow: 0).height, primaryHeight)
    }

    func testNativeFieldsFitCompleteVerseTextAtActualRowWidths() async throws {
        let subject = controller()
        let window = mountedWindow(subject)
        defer { window.close() }
        let text = "For God so loved the world, that he gave his only begotten Son, that whosoever believes in him should not perish, but have everlasting life."
        let reference = VerseReference(book: "John", chapter: 3, verse: 16)!
        let rows = [NativeReferenceRow(reference: reference, primaryText: text, secondaryText: text),
                    NativeReferenceRow(reference: row(2).reference, primaryText: "ദൈവം ലോകത്തെ സ്നേഹിച്ചു. " + text,
                                       secondaryText: String(repeating: "בראשית ברא אלהים ", count: 12))]
        for width: CGFloat in [640, 701, 1000] {
            for dual in [true, false] {
                window.setContentSize(NSSize(width: width, height: 1000))
                subject.apply(rows: rows, selection: reference, style: .verses(fontSize: 17, dual: dual))
                try await settle(subject)
                XCTAssertTrue(subject.table.usesAutomaticRowHeights)
                for index in rows.indices {
                    let cell = try XCTUnwrap(subject.table.view(atColumn: 0, row: index, makeIfNecessary: true))
                    cell.layoutSubtreeIfNeeded()
                    let fields = cell.subviews.compactMap { $0 as? NSTextField }
                        .filter { !$0.isHidden && $0.maximumNumberOfLines == 0 }
                    for field in fields {
                        let needed = try XCTUnwrap(field.cell).cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 10000))
                        XCTAssertGreaterThanOrEqual(field.bounds.height + 0.5, needed.height, "\(width), \(dual): \(field.stringValue)")
                        XCTAssertLessThanOrEqual(field.frame.maxY, cell.bounds.height - 33)
                    }
                    let rowView = try XCTUnwrap(subject.table.rowView(atRow: index, makeIfNecessary: true))
                    XCTAssertEqual(rowView.frame.height, subject.table.rect(ofRow: index).height, accuracy: 1)
                }
            }
        }
    }

    func testResponderCommandsAndControlNUseTheSameNavigationIntents() {
        let subject = controller()
        let rows = (1...5).map { row($0) }
        var activations: [Int] = []
        var stops = 0
        subject.onActivate = { activations.append($0.verse) }
        subject.onCancel = { stops += 1 }
        subject.apply(rows: rows, selection: rows[0].reference, style: .verses(fontSize: 17, dual: false))
        subject.table.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let controlN = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "\u{E}",
                                        charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
        subject.table.keyDown(with: controlN)
        subject.table.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(activations, [2, 3])
        XCTAssertEqual(stops, 1)
    }

    private func mountedWindow(_ subject: NativeReferenceTableController) -> NSWindow {
        let window = NSWindow(contentRect: subject.scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = subject.scrollView
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        return window
    }

    private func settle(_ subject: NativeReferenceTableController) async throws {
        subject.scrollView.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 30_000_000)
        subject.scrollView.layoutSubtreeIfNeeded()
    }

    private func waitForReveal(_ subject: NativeReferenceTableController, aligned: () -> Bool) async throws {
        for _ in 0..<50 {
            try await settle(subject)
            if aligned() { return }
        }
    }

    func testSnapshotRefreshDoesNotStealFocus() {
        let subject = controller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: subject.scrollView.frame)
        let other = FocusProbe(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        root.addSubview(subject.scrollView)
        root.addSubview(other)
        window.contentView = root
        defer { window.close() }
        window.makeFirstResponder(subject.table)
        XCTAssertTrue(window.firstResponder === subject.table)
        XCTAssertTrue(window.makeFirstResponder(other))
        let item = row(1)
        subject.apply(rows: [item], selection: item.reference, style: .verses(fontSize: 17, dual: false))
        XCTAssertTrue(window.firstResponder === other)
        window.makeFirstResponder(subject.table)
        XCTAssertTrue(window.firstResponder === subject.table)
    }

    func testBookmarkRefreshPreservesScrollAndNewSubmissionRevealsSelection() async throws {
        let subject = controller()
        let window = mountedWindow(subject)
        defer { window.close() }
        var rows = (1...100).map { row($0) }
        let request = UUID()
        subject.apply(rows: rows, selection: rows[0].reference, style: .verses(fontSize: 17, dual: false), scrollRequest: request)
        try await settle(subject)
        subject.table.scrollRowToVisible(70)
        try await settle(subject)
        let previousY = subject.scrollView.contentView.bounds.minY
        XCTAssertGreaterThan(previousY, 0)
        rows[70].bookmarked = true
        subject.apply(rows: rows, selection: rows[0].reference, style: .verses(fontSize: 17, dual: false), scrollRequest: request)
        try await settle(subject)
        XCTAssertEqual(subject.scrollView.contentView.bounds.minY, previousY, accuracy: 1)
        subject.apply(rows: rows, selection: rows[0].reference, style: .verses(fontSize: 17, dual: false), scrollRequest: UUID())
        try await settle(subject)
        XCTAssertEqual(subject.scrollView.contentView.bounds.minY, 0, accuracy: 1)
        subject.apply(rows: rows, selection: rows[89].reference, style: .verses(fontSize: 17, dual: false), scrollRequest: UUID())
        try await settle(subject)
        XCTAssertTrue(subject.table.visibleRect.intersects(subject.table.rect(ofRow: 89)))
    }

    func testChapterRevealUsesWrappedHeightAndKeepsOversizedVerseStartVisible() async throws {
        let subject = controller()
        let window = mountedWindow(subject)
        defer { window.close() }
        let origin = (1...2).map { row($0, chapter: 117) }
        let destination = (1...17).map { number in
            let reference = VerseReference(book: "Esther", chapter: 8, verse: number)!
            return NativeReferenceRow(reference: reference,
                primaryText: String(repeating: "A long verse wraps across the available text width. ", count: number == 9 ? 12 : number % 3 + 2),
                secondaryText: String(repeating: "ദൈവം സ്നേഹമാകുന്നു. ", count: number == 9 ? 24 : 4))
        }
        for (width, dual) in [(700.0, false), (350.0, true)] {
            window.setContentSize(NSSize(width: width, height: 400))
            let style = NativeReferenceStyle.verses(fontSize: 17, dual: dual)
            subject.apply(rows: origin, selection: origin[1].reference, style: style, scrollRequest: UUID())
            try await settle(subject)
            subject.apply(rows: destination, selection: destination[8].reference, style: style, scrollRequest: UUID())
            try await waitForReveal(subject) {
                let target = subject.table.rect(ofRow: 8)
                let viewport = subject.table.visibleRect
                return abs(dual ? target.minY - viewport.minY : target.midY - viewport.midY) <= 1
            }
            let target = subject.table.rect(ofRow: 8)
            let viewport = subject.table.visibleRect
            if dual {
                XCTAssertGreaterThan(target.height, viewport.height)
                XCTAssertEqual(target.minY, viewport.minY, accuracy: 1)
            } else {
                XCTAssertLessThan(target.height, viewport.height)
                XCTAssertEqual(target.midY, viewport.midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(target.minY, viewport.minY)
                XCTAssertLessThanOrEqual(target.maxY, viewport.maxY)
            }
        }
    }

    func testNewNavigationSupersedesPendingVerseReveal() async throws {
        let subject = controller()
        let window = mountedWindow(subject)
        defer { window.close() }
        let first = (1...100).map { row($0, chapter: 119) }
        let second = (1...17).map { row($0, book: "Esther", chapter: 8) }
        let style = NativeReferenceStyle.verses(fontSize: 17, dual: false)
        subject.apply(rows: first, selection: first[89].reference, style: style, scrollRequest: UUID())
        subject.apply(rows: second, selection: second[8].reference, style: style, scrollRequest: UUID())
        try await waitForReveal(subject) {
            abs(subject.table.rect(ofRow: 8).midY - subject.table.visibleRect.midY) <= 1
        }
        XCTAssertEqual(subject.selectedReference, second[8].reference)
        XCTAssertEqual(subject.table.rect(ofRow: 8).midY, subject.table.visibleRect.midY, accuracy: 1)
    }

    func testAppendingSearchPagePreservesVisibleReferenceAndOffset() async throws {
        let subject = controller()
        let window = mountedWindow(subject)
        defer { window.close() }
        let rows = (1...200).map { number in
            var item = row(number % 100 + 1, chapter: number / 100 + 1)
            item.secondaryText = String(repeating: "ദൈവം സ്നേഹമാകുന്നു. ", count: number % 7 + 1)
            item.heading = item.reference.verseQuery.title
            return item
        }
        let style = NativeReferenceStyle.results(fontSize: 17, dual: true)
        let searchID = UUID()
        subject.activatesOnSelection = false
        subject.apply(rows: Array(rows.prefix(100)), selection: rows[0].reference, style: style, scrollRequest: searchID)
        try await settle(subject)
        subject.table.scrollRowToVisible(99)
        try await settle(subject)
        let top = subject.table.rows(in: subject.table.visibleRect).location
        let reference = subject.rows[top].reference
        let offset = subject.table.visibleRect.minY - subject.table.rect(ofRow: top).minY
        XCTAssertGreaterThan(top, 0)
        subject.apply(rows: Array(rows.prefix(100)), selection: rows[0].reference, style: style, enabled: false, scrollRequest: searchID)
        subject.apply(rows: Array(rows.prefix(150)), selection: rows[0].reference, style: style, scrollRequest: searchID)
        try await settle(subject)
        let restoredTop = subject.table.rows(in: subject.table.visibleRect).location
        XCTAssertEqual(subject.rows[restoredTop].reference, reference)
        XCTAssertEqual(subject.table.visibleRect.minY - subject.table.rect(ofRow: restoredTop).minY, offset, accuracy: 1)
        XCTAssertEqual(subject.selectedReference, rows[0].reference)

        // Even if a new query extends the old rows, its new ID must reveal the selection.
        subject.apply(rows: rows, selection: rows[0].reference, style: style, scrollRequest: UUID())
        try await settle(subject)
        XCTAssertTrue(subject.table.visibleRect.intersects(subject.table.rect(ofRow: 0)))
        subject.table.scrollRowToVisible(90)
        subject.apply(rows: Array(rows.suffix(100)), selection: rows[100].reference, style: style, scrollRequest: UUID())
        try await settle(subject)
        XCTAssertTrue(subject.table.visibleRect.intersects(subject.table.rect(ofRow: 0)))
    }

    func testCopyMenuValidationFollowsSelectionTranslationAndLoading() {
        let subject = controller()
        let copy = NSMenuItem(title: "Copy", action: #selector(ReferenceNSTableView.copy(_:)), keyEquivalent: "c")
        var item = row(1)
        item.primaryCopy = nil
        item.secondaryCopy = "Secondary text"
        subject.apply(rows: [item], selection: item.reference, style: .verses(fontSize: 17, dual: true))
        XCTAssertTrue(subject.table.validateMenuItem(copy))
        subject.apply(rows: [item], selection: item.reference, style: .verses(fontSize: 17, dual: false))
        XCTAssertFalse(subject.table.validateMenuItem(copy))
        subject.apply(rows: [item], selection: item.reference, style: .verses(fontSize: 17, dual: true), enabled: false)
        XCTAssertFalse(subject.table.validateMenuItem(copy))
        subject.apply(rows: [item], selection: nil, style: .verses(fontSize: 17, dual: true))
        XCTAssertFalse(subject.table.validateMenuItem(copy))
        subject.apply(rows: [item], selection: item.reference, style: .chapters)
        XCTAssertFalse(subject.table.validateMenuItem(copy))
    }

    func testContextMenuKeepsItsReferenceAfterRowsChange() {
        let subject = controller()
        var item = row(15, book: "3 John")
        item.primaryCopy = nil
        item.secondaryCopy = "3 John 1:15 secondary text"
        var bookmarked: VerseReference?
        var opened: VerseReference?
        subject.onBookmark = { bookmarked = $0 }
        subject.onOpenInNewTab = { opened = $0 }
        subject.apply(rows: [item], selection: item.reference, style: .verses(fontSize: 17, dual: true))
        let menu = subject.contextMenu(at: 0)!
        XCTAssertEqual(menu.items.map(\.title), ["Copy Verse (Secondary)", "Open in New Tab", "", "Add Bookmark"])
        let replacement = row(1, book: "1 Peter")
        subject.apply(rows: [replacement], selection: replacement.reference, style: .verses(fontSize: 17, dual: true))
        let bookmarkItem = menu.items.last!
        XCTAssertTrue(NSApp.sendAction(bookmarkItem.action!, to: bookmarkItem.target, from: bookmarkItem))
        XCTAssertEqual(bookmarked, item.reference)
        let openItem = menu.items.first { $0.title == "Open in New Tab" }!
        XCTAssertTrue(NSApp.sendAction(openItem.action!, to: openItem.target, from: openItem))
        XCTAssertEqual(opened, item.reference)
        subject.apply(rows: [replacement], selection: replacement.reference, style: .verses(fontSize: 17, dual: false), enabled: false)
        XCTAssertNil(subject.contextMenu(at: 0))
    }

    func testAccessibilityActivationUsesTheRowReferenceAndHonorsLoading() {
        let subject = controller()
        let rows = [row(13, book: "3 John"), row(15, book: "3 John")]
        var activations: [VerseReference] = []
        subject.onActivate = { activations.append($0) }
        subject.apply(rows: rows, selection: rows[0].reference, style: .verses(fontSize: 17, dual: true))
        let rowView = subject.tableView(subject.table, rowViewForRow: 1)!
        XCTAssertEqual(rowView.accessibilityCustomActions()?.first?.name, "Project verse")
        XCTAssertTrue(rowView.accessibilityPerformPress())
        XCTAssertEqual(subject.selectedReference, rows[1].reference)
        XCTAssertEqual(rowView.accessibilityCustomActions()?.first?.handler?(), true)
        XCTAssertEqual(activations, [rows[1].reference, rows[1].reference])
        subject.apply(rows: rows, selection: rows[1].reference, style: .verses(fontSize: 17, dual: true), enabled: false)
        XCTAssertFalse(rowView.accessibilityPerformPress())
        subject.apply(rows: [row(1)], selection: nil, style: .chapters)
        XCTAssertFalse(rowView.accessibilityPerformPress())
        XCTAssertEqual(activations.count, 2)
        let chapterRow = subject.tableView(subject.table, rowViewForRow: 0)!
        XCTAssertEqual(chapterRow.accessibilityCustomActions()?.first?.name, "Open chapter")
    }
}

@MainActor private final class FocusProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
}

// Exercise active-window mouse handling without activating an offscreen test app.
