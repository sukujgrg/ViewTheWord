import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var library: BibleLibrary = .shared
    private enum Tabs: Hashable {
        case font
        case bible
    }

    var body: some View {
        TabView {
            DisplaySettingsView()
                .tabItem {
                    Label("Display", systemImage: "display")
                }
                .tag(Tabs.font)
            BibleImportView(library: library)
                .tabItem {
                    Label("Bible", systemImage: "book")
                }
                .tag(Tabs.bible)
        }
        .padding(20)
        .frame(width: 500, height: 400)
    }
}

struct DisplaySettingsView: View {
    @AppStorage(AppDefaultsKey.fontSizeVerse) private var fontSizeVerse = AppDefaults.verseFontSize
    @AppStorage(AppDefaultsKey.fontSizeVerseRef) private var fontSizeVerseRef = AppDefaults.referenceFontSize
    @AppStorage(AppDefaultsKey.projectorPadding) private var vStackPadding = AppDefaults.projectorPadding

    @State private var fontSizeVerseDraft = AppDefaults.verseFontSize
    @State private var fontSizeVerseRefDraft = AppDefaults.referenceFontSize
    @State private var vStackPaddingDraft = AppDefaults.projectorPadding

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Font Size") {
                VStack(alignment: .leading, spacing: 14) {
                    sliderRow(
                        title: "Verse",
                        valueText: String(format: "%.0f pts", fontSizeVerseDraft)
                    )
                    Slider(value: $fontSizeVerseDraft, in: 40 ... 200, step: 1, onEditingChanged: { isEditing in
                        if !isEditing {
                            persistFontSettings()
                        }
                    })

                    sliderRow(
                        title: "Verse reference",
                        valueText: String(format: "%.0f pts", fontSizeVerseRefDraft)
                    )
                    Slider(value: $fontSizeVerseRefDraft, in: 20 ... 72, step: 1, onEditingChanged: { isEditing in
                        if !isEditing {
                            persistFontSettings()
                        }
                    })

                    sliderRow(
                        title: "Padding",
                        valueText: String(format: "%.0f pts", vStackPaddingDraft)
                    )
                    Slider(value: $vStackPaddingDraft, in: 10 ... 200, step: 1, onEditingChanged: { isEditing in
                        if !isEditing {
                            persistFontSettings()
                        }
                    })
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 4)
        .onAppear {
            fontSizeVerseDraft = fontSizeVerse
            fontSizeVerseRefDraft = fontSizeVerseRef
            vStackPaddingDraft = vStackPadding
        }
        .onDisappear {
            persistFontSettings()
        }
    }

    private func persistFontSettings() {
        if fontSizeVerse != fontSizeVerseDraft {
            fontSizeVerse = fontSizeVerseDraft
        }

        if fontSizeVerseRef != fontSizeVerseRefDraft {
            fontSizeVerseRef = fontSizeVerseRefDraft
        }

        if vStackPadding != vStackPaddingDraft {
            vStackPadding = vStackPaddingDraft
        }
    }

    @ViewBuilder
    private func sliderRow(title: String, valueText: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(valueText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }
}

struct BibleImportView: View {
    @ObservedObject var library: BibleLibrary
    @AppStorage(AppDefaultsKey.primaryBibleName) private var primaryBibleName = bundledPrimaryBibleUrl?.absoluteString ?? ""
    @AppStorage(AppDefaultsKey.secondaryBibleName) private var secondaryBibleName = bundledSecondaryBibleUrl?.absoluteString ?? ""
    @State private var showImporter = false
    @State private var removing: URL?
    private let bibleType = UTType(exportedAs: "com.viewtheword.sqlite3.database", conformingTo: .database)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                translationPicker("Primary", selection: $primaryBibleName)
                translationPicker("Secondary", selection: $secondaryBibleName)
            }
            HStack {
                Button("Import Bible…", systemImage: "book.circle") { showImporter = true }
                    .disabled(library.isImporting)
                if library.isImporting { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("Choose a .bible translation to add it to both translation pickers. Import the same file name again to replace an imported translation.")
                .font(.callout).foregroundStyle(.secondary)
            List(library.urls, id: \.absoluteString) { url in
                HStack {
                    VStack(alignment: .leading) {
                        Text(BibleTranslation.name(for: url))
                        Text(library.isImported(url) ? "Imported · " + url.lastPathComponent : "Included with the app")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.isImported(url) {
                        Button("Remove", role: .destructive) { removing = url }
                            .disabled(library.isImporting)
                    }
                }
            }.listStyle(.inset)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [bibleType, .database], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { library.importFile(url, presenter: .settings) }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { library.showNotice(error.localizedDescription, presenter: .settings) }
            }
        }
        .confirmationDialog("Remove imported translation?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { url in
            Button("Move to Trash", role: .destructive) { library.removeImported(url) }
        } message: { url in
            Text("\(BibleTranslation.name(for: url)) will be moved to Trash. A selected translation will fall back to an available Bible.")
        }
    }

    private func translationPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(library.urls, id: \.absoluteString) { url in
                Text(BibleTranslation.name(for: url)).tag(url.absoluteString)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("\(title) translation")
    }
}
