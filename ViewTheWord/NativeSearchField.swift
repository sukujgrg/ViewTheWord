import AppKit

@MainActor
final class NativeSearchFieldController: NSObject, NSSearchFieldDelegate {
    let field = NSSearchField()
    private var didClearEmptyDraft = false
    private(set) var interactionRevision = 0
    private(set) var isSendingSubmission = false
    var onTextChange: (String) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onClear: () -> Void = {}
    var onMoveFocus: (Int) -> Void = { _ in }
    var onCancel: () -> Void = {}

    override init() {
        super.init()
        field.delegate = self
        field.target = self
        field.action = #selector(submit(_:))
        field.sendsWholeSearchString = true
        field.maximumRecents = 12
        field.controlSize = .large
        // Keep the text and native search/cancel glyphs on AppKit's control metrics.
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: field.controlSize))
        field.setAccessibilityLabel("Verse search or text search")
        // Keep general help stable; the native placeholder supplies the
        // selected mode's example when the search field is empty.
        field.placeholderString = "Search"
        let help = "Ref: John 3:16. Words: faith AND hope (AND, OR, NOT). Phrase: in the beginning. Press Return to search. Command-L focuses Search."
        field.toolTip = help
        field.setAccessibilityHelp(help)
        let menu = NSMenu(title: "Recent Searches")
        for (title, tag) in [
            ("Recent Searches", NSSearchField.recentsTitleMenuItemTag),
            ("Recents", NSSearchField.recentsMenuItemTag),
            ("Clear Recent Searches", NSSearchField.clearRecentsMenuItemTag),
            ("No Recent Searches", NSSearchField.noRecentsMenuItemTag)
        ] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").tag = tag
        }
        field.searchMenuTemplate = menu
    }

    func apply(text: String, placeholder: String, recentsName: String? = nil) {
        // Assigning stringValue during every snapshot would reset the field editor.
        if field.stringValue != text { field.stringValue = text }
        if !text.isEmpty { didClearEmptyDraft = false }
        // AppKit owns any editing transition needed for a new placeholder.
        // Unchanged snapshots must not ask it to perform that transition again.
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if field.recentsAutosaveName != recentsName { field.recentsAutosaveName = recentsName }
    }

    func focus(using toolbarItem: NSSearchToolbarItem) {
        // Record the explicit intent even when already editing so an older
        // submission cannot move focus. Ask AppKit for focus only when needed.
        interactionRevision += 1
        if let editor = field.currentEditor(), field.window?.firstResponder === editor { return }
        toolbarItem.beginSearchInteraction()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        interactionRevision += 1
        if let editor = field.currentEditor() as? NSTextView {
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        interactionRevision += 1
        if !field.stringValue.isEmpty { didClearEmptyDraft = false }
        onTextChange(field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // AppKit can send this before or after Return's target action. It is
        // part of the same submission, not a newer focus change.
        if notification.userInfo?[NSText.movementUserInfoKey] as? Int != NSTextMovement.return.rawValue {
            interactionRevision += 1
        }
    }

    @objc func submit(_ sender: NSSearchField) {
        // Choosing a recent search can send an action without a text-change delegate call.
        if sender.stringValue.isEmpty {
            // AppKit can send multiple actions while its cancel button ends editing.
            guard !didClearEmptyDraft else { return }
            didClearEmptyDraft = true
            onTextChange("")
            onClear()
        } else {
            didClearEmptyDraft = false
            // Return can temporarily resign the field editor before sending
            // this action. Keep that native transition within this submission.
            isSendingSubmission = true
            defer { isSendingSubmission = false }
            onTextChange(sender.stringValue)
            onSubmit()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)): onMoveFocus(-1)
        case #selector(NSResponder.moveDown(_:)): onMoveFocus(1)
        case #selector(NSResponder.cancelOperation(_:)): onCancel()
        default: return false
        }
        return true
    }
}
