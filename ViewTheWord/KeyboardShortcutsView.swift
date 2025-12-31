//
//  KeyboardShortcutsView.swift
//  ViewTheWord
//
//  Keyboard shortcuts help overlay
//

import SwiftUI

struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) var dismiss

    let searchTips: [(category: String, items: [(example: String, description: String)])] = [
        ("Verse Reference", [
            ("John 3:16", "Go to specific verse"),
            ("gen 1:1", "Book name abbreviation works"),
            ("1 cor 13", "Goes to chapter 13, verse 1")
        ]),
        ("Phrase Search (s:)", [
            ("s: jesus wept", "Exact phrase match"),
            ("s: in the beginning", "Finds exact phrase"),
            ("s: ot: the lord", "Search Old Testament only"),
            ("s: nt: believe", "Search New Testament only"),
            ("s: john: light", "Search in book of John")
        ]),
        ("Multi-term Search (m:)", [
            ("m: jesus AND mary", "Both words must appear"),
            ("m: jesus OR christ", "Either word appears"),
            ("m: love AND NOT hate", "Include love, exclude hate"),
            ("m: god AND (love OR mercy)", "Grouping with parentheses"),
            ("m: nt: faith AND hope", "Multi-term in New Testament"),
            ("m: john: light AND darkness", "Multi-term in specific book")
        ])
    ]

    let keyboardShortcuts: [(category: String, items: [(keys: String, description: String)])] = [
        ("Verse Navigation", [
            ("↑ / ↓", "Previous/next verse"),
            ("⌘ ↑ / ⌘ ↓", "Jump 5 verses"),
            ("⌥ ↑ / ⌥ ↓", "Previous/next chapter"),
            ("Page Up/Down", "Jump 10 verses"),
            ("Home / End", "First/last verse"),
            ("Space", "Toggle projector"),
            ("Tab", "Cycle through columns")
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
            .background(Color(NSColor.windowBackgroundColor))

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
                                                .background(Color(NSColor.controlBackgroundColor))
                                                .cornerRadius(4)
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
                                                .background(Color(NSColor.controlBackgroundColor))
                                                .cornerRadius(4)
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
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 900, height: 600)
    }
}

#Preview {
    KeyboardShortcutsView()
}
