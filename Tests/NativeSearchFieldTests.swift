import AppKit
import XCTest
@testable import ViewTheWordCore

@MainActor
final class NativeSearchFieldTests: XCTestCase {
    func testEditingDoesNotSubmitAndRecentSearchActionUpdatesDraftFirst() {
        _ = NSApplication.shared
        let subject = NativeSearchFieldController()
        var draft = ""
        var submitted: [String] = []
        subject.onTextChange = { draft = $0 }
        subject.onSubmit = { [weak subject] in
            XCTAssertEqual(subject?.isSendingSubmission, true)
            submitted.append(draft)
        }
        subject.apply(text: "", placeholder: "John 3:16", accessibilityHint: "Search")
        subject.field.stringValue = "John 3"
        subject.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: subject.field))
        XCTAssertEqual(draft, "John 3")
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertTrue(subject.field.sendsWholeSearchString)
        XCTAssertNotNil(subject.field.searchMenuTemplate)
        XCTAssertNil(subject.field.recentsAutosaveName)

        // Native recents selection sends the action without necessarily ending editing.
        subject.field.recentSearches = ["John 3:16"]
        subject.field.stringValue = "John 3:16"
        subject.field.sendAction(subject.field.action, to: subject.field.target)
        XCTAssertEqual(submitted, ["John 3:16"])
        XCTAssertFalse(subject.isSendingSubmission)
    }

    func testClearAndEscapeHaveSeparateIntentsAndDoNotSubmit() {
        _ = NSApplication.shared
        let subject = NativeSearchFieldController()
        var draft = "John 3:16"
        var clears = 0, stops = 0, submits = 0
        var moves: [Int] = []
        subject.onTextChange = { draft = $0 }
        subject.onClear = { clears += 1 }
        subject.onCancel = { stops += 1 }
        subject.onSubmit = { submits += 1 }
        subject.onMoveFocus = { moves.append($0) }
        subject.apply(text: draft, placeholder: "", accessibilityHint: "")
        let editor = NSTextView()
        XCTAssertTrue(subject.control(subject.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(draft, "John 3:16")
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(clears, 0)
        subject.field.stringValue = ""
        subject.field.sendAction(subject.field.action, to: subject.field.target)
        XCTAssertEqual(draft, "")
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(submits, 0)
        XCTAssertTrue(subject.control(subject.field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(subject.control(subject.field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(moves, [-1, 1])
        XCTAssertFalse(subject.control(subject.field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        XCTAssertFalse(subject.control(subject.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }

    func testSnapshotPreservesCaretAndOnlyExplicitRequestRefocuses() throws {
        _ = NSApplication.shared
        let subject = NativeSearchFieldController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        subject.field.frame = NSRect(x: 10, y: 50, width: 275, height: 35)
        let other = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 25))
        root.addSubview(subject.field)
        root.addSubview(other)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        subject.apply(text: "John 3:16", placeholder: "", accessibilityHint: "")
        window.makeFirstResponder(subject.field)
        let editor = try XCTUnwrap(subject.field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        subject.apply(text: "John 3:16", placeholder: "New prompt", accessibilityHint: "")
        XCTAssertTrue(subject.field.currentEditor() === editor)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0))
        XCTAssertTrue(window.makeFirstResponder(other))
        subject.apply(text: "John 3:16", placeholder: "", accessibilityHint: "")
        XCTAssertNotNil(other.currentEditor())
        XCTAssertNil(subject.field.currentEditor())
        subject.apply(text: "John 3:16", placeholder: "", accessibilityHint: "")
        window.makeFirstResponder(subject.field)
        XCTAssertNotNil(subject.field.currentEditor())
        XCTAssertNil(other.currentEditor())
    }

    func testNativeFieldEditorSubmitsOnceAndEscapePreservesDraft() throws {
        _ = NSApplication.shared
        let subject = NativeSearchFieldController()
        var submits = 0, stops = 0, clears = 0
        var draft = "John 3:16"
        subject.onSubmit = { submits += 1 }
        subject.onCancel = { stops += 1 }
        subject.onClear = { clears += 1 }
        subject.onTextChange = { draft = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        subject.field.frame = NSRect(x: 10, y: 10, width: 275, height: 35)
        root.addSubview(subject.field)
        window.contentView = root
        defer { window.close() }
        subject.apply(text: draft, placeholder: "", accessibilityHint: "")
        window.makeFirstResponder(subject.field)
        func send(_ characters: String, code: UInt16) throws {
            let editor = try XCTUnwrap(subject.field.currentEditor() as? NSTextView)
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
            editor.keyDown(with: event)
        }
        try send("\r", code: 36)
        XCTAssertEqual(submits, 1)
        window.makeFirstResponder(subject.field)
        try send("\u{1B}", code: 53)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(draft, "John 3:16")
        let cell = try XCTUnwrap(subject.field.cell as? NSSearchFieldCell)
        try XCTUnwrap(cell.cancelButtonCell).performClick(subject.field)
        XCTAssertEqual(draft, "")
        XCTAssertEqual(clears, 1)
        XCTAssertEqual(submits, 1)
        XCTAssertEqual(stops, 1)
    }
}
