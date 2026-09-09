import SwiftUI

// Separate hosted screens; the main workspace contains only AppKit views.
struct KeyboardShortcutsView: View {
    var dismiss: () -> Void = {}

    let searchTips: [(category: String, items: [(example: String, description: String)])] = [
        ("Mode Toggle", [
            ("Ref / Words / Phrase", "Use the toggle to the right of search field")
        ]),
        ("Verse Reference", [
            ("John 3:16", "Go to specific verse"),
            ("gen 1:1", "Book name abbreviation works"),
            ("1 cor 13", "Goes to chapter 13, verse 1")
        ]),
        ("Phrase Search (Phrase Mode)", [
            ("his only begotten son", "Exact phrase match"),
            ("in the beginning", "Finds exact phrase"),
            ("ot: the lord", "Search Old Testament only"),
            ("nt: believe", "Search New Testament only"),
            ("john: light", "Search in book of John")
        ]),
        ("Word Search (Words Mode)", [
            ("jesus AND mary", "Both words must appear; adjacent words also use AND"),
            ("jesus OR christ", "Either word appears"),
            ("love AND NOT hate", "Include love, exclude hate"),
            ("god AND (love OR mercy)", "Grouping with parentheses"),
            ("nt: faith AND hope", "Search in New Testament"),
            ("john: light AND darkness", "Search in specific book")
        ])
    ]

    let keyboardShortcuts: [(category: String, items: [(keys: String, description: String)])] = [
        ("Passage Tabs", [
            ("⌘ T", "New passage tab"),
            ("⌘ Return", "Open selected passage in a new tab"),
            ("⌘ W", "Close tab; live output continues"),
            ("⌃ Tab / ⌃ ⇧ Tab", "Next/previous tab"),
            ("Drag a tab", "Reorder passages")
        ]),
        ("Chapter Grid", [
            ("↑ / ↓ / ← / →", "Move between chapter numbers"),
            ("Return / Space", "Open selected chapter"),
            ("⌘ ← / ⌘ →", "Move to books or search")
        ]),
        ("Verse Navigation", [
            ("↑ / ↓", "Previous/next verse"),
            ("⌘ ↑ / ⌘ ↓", "Jump 5 verses"),
            ("⌥ ↑ / ⌥ ↓", "Previous/next chapter"),
            ("Page Up/Down", "Jump 10 verses"),
            ("Home / End", "First/last verse"),
            ("Space", "Toggle projector"),
            ("Tab / ⇧ Tab", "Move between controls")
        ]),
        ("Search Results", [
            ("↑ / ↓", "Select a result"),
            ("Return / Space", "Project selected result")
        ]),
        ("General", [
            ("⌘ L", "Focus search field"),
            ("Return", "Search/display verse"),
            ("Escape", "Clear projector"),
            ("⌘ /", "Show this help"),
            ("⌘ ,", "Open Settings"),
            ("⌘ Q", "Quit application")
        ])
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Help")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.regularMaterial)

            Divider()

            // Two-column content
            HStack(alignment: .top, spacing: 0) {
                // Left column: Search Tips
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Search Tips")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.bottom, 4)

                        ForEach(searchTips, id: \.category) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.category)
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                VStack(spacing: 6) {
                                    ForEach(section.items, id: \.example) { item in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.example)
                                                .font(.system(.body, design: .monospaced))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                        .fill(.thinMaterial)
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                        .stroke(.quaternary, lineWidth: 1)
                                                )
                                                .frame(maxWidth: .infinity, alignment: .leading)

                                            Text(item.description)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .padding(.leading, 8)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity)

                Divider()

                // Right column: Keyboard Shortcuts
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Keyboard Shortcuts")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.bottom, 4)

                        ForEach(keyboardShortcuts, id: \.category) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.category)
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                VStack(spacing: 6) {
                                    ForEach(section.items, id: \.keys) { shortcut in
                                        HStack(spacing: 12) {
                                            Text(shortcut.keys)
                                                .font(.system(.body, design: .monospaced))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                        .fill(.thinMaterial)
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                                        .stroke(.quaternary, lineWidth: 1)
                                                )
                                                .frame(width: 100, alignment: .leading)

                                            Text(shortcut.description)
                                                .font(.body)
                                                .foregroundColor(.secondary)

                                            Spacer()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(.regularMaterial)
        }
        .frame(width: 900, height: 600)
    }
}

