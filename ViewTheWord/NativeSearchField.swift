import AppKit

@MainActor
final class NativeSearchFieldController: NSObject, NSSearchFieldDelegate {
    let field = ReferenceSearchField()
    private var didClearEmptyDraft = false
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

    func apply(text: String, placeholder: String, accessibilityHint: String,
               recentsName: String? = nil) {
        // Assigning stringValue during every snapshot would reset the field editor.
        if field.stringValue != text { field.stringValue = text }
        if !text.isEmpty { didClearEmptyDraft = false }
        field.placeholderString = placeholder
        field.setAccessibilityHelp(accessibilityHint)
        if field.recentsAutosaveName != recentsName { field.recentsAutosaveName = recentsName }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if let editor = field.currentEditor() as? NSTextView {
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if !field.stringValue.isEmpty { didClearEmptyDraft = false }
        onTextChange(field.stringValue)
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

@MainActor
final class ReferenceSearchField: NSSearchField {}
