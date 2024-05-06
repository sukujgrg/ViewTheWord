import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum Tabs: Hashable {
        case general
        case font
        case bible
    }

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(Tabs.general)
            DisplaySettingsView()
                .tabItem {
                    Label("Display", systemImage: "display")
                }
                .tag(Tabs.font)
            BibleImportView()
                .tabItem {
                    Label("Bible", systemImage: "book")
                }
                .tag(Tabs.bible)
        }
        .padding(20)
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("history") private var history: [String] = ["John 3 16"]

    var body: some View {
        VStack(alignment: .leading) {
            Button("Clear History") {
                history.removeAll()
            }
        }
    }
}

struct DisplaySettingsView: View {
    @AppStorage("fontSizeVerse") private var fontSizeVerse = 100.0
    @AppStorage("fontSizeVerseRef") private var fontSizeVerseRef = 20.0
    @AppStorage("vStackPadding") private var vStackPadding = 20.0
    @AppStorage("transparentBackground") var transparentBackground = false

    var body: some View {
        VStack {
            List {
                Section(header: Text("Font Size")) {
                    Slider(value: $fontSizeVerse, in: 40 ... 200) {
                        Text("Verse (\(fontSizeVerse, specifier: "%.0f") pts)")
                    }
                    Slider(value: $fontSizeVerseRef, in: 20 ... 50) {
                        Text("Verse reference (\(fontSizeVerseRef, specifier: "%.0f") pts)")
                    }
                    Slider(value: $vStackPadding, in: 10 ... 200) {
                        Text("Padding (\(vStackPadding, specifier: "%.0f") pts)")
                    }
                }
                .headerProminence(.increased)

                Section(header: Text("Background")) {
                    Toggle("Transparent background", isOn: $transparentBackground)
                }
                .headerProminence(.increased)
            }
            .listStyle(.inset)
        }
    }
}

struct BibleImportView: View {
    @State var showFileChooser = false
    @State private var isImporting: Bool = false

    @AppStorage("PrimaryBibleName") private var primaryBibleName: String = bundledPrimaryBibleUrl.absoluteString
    @AppStorage("SecondaryBibleName") private var secondaryBibleName: String = bundledSecondaryBibleUrl.absoluteString
    @AppStorage("showOnlyPrimary") var showOnlyPrimary = false
    @AppStorage("scrollTo") var scrollTo = true

    let bibleType = UTType(exportedAs: "com.viewtheword.sqlite3.database", conformingTo: .database)

    var body: some View {
        VStack {
            HStack {
                Button(action: { isImporting = true }, label: {
                    Text("Import Bible")
                })
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [bibleType],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let selectedFile: URL = try result.get().first else { return }
                    importBibleDb(selectedFile: selectedFile)
                } catch {
                    logger.error("\(error.localizedDescription)")
                }
            }
            Toggle("Show only Primary Verse", isOn: $showOnlyPrimary)
            Toggle("Scroll to the current verse automatically", isOn: $scrollTo)


            HStack {
                Picker(selection: $primaryBibleName, label: Text("Primary")) {
                    ForEach(bibleUrls(), id: \.absoluteString) { name in
                        Text(String(name.lastPathComponent))
                    }
                }.onChange(of: primaryBibleName) { _, name in
                    primaryBibleName = name
                }
                Divider()
                Picker(selection: $secondaryBibleName, label: Text("Secondary")) {
                    ForEach(bibleUrls(), id: \.absoluteString) { name in
                        Text(name.lastPathComponent)
                    }
                }.onChange(of: secondaryBibleName) { _, name in
                    secondaryBibleName = name
                }
                .disabled(showOnlyPrimary)
            }
            .pickerStyle(.radioGroup)
        }
    }

    func bibleUrls() -> [URL] {
        let bibleUrl = BibleUrl()
        return bibleUrl.getAvailableBibleUrls()
    }

    func isValidBibleFileName(selectedFileName: String) -> Bool {
        if selectedFileName.range(of: #"\b[A-Z]{3}_[A-Z]{3,6}.bible\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    func importBibleDb(selectedFile: URL) {
        guard isValidBibleFileName(selectedFileName: selectedFile.lastPathComponent) else {
            logger.error("\(selectedFile.lastPathComponent) is an invalid bible db name. It should be in '<LANG>_<NAME>.bible' format.")
            return
        }
        let fileManager = FileManager.default
        let bundledBible = [bundledPrimaryBibleUrl.lastPathComponent, bundledSecondaryBibleUrl.lastPathComponent]
        if !bundledBible.contains(selectedFile.lastPathComponent) {
            let docDir = try! FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let documentsURL = docDir.appendingPathComponent(selectedFile.lastPathComponent)
            do {
                try fileManager.copyItem(at: selectedFile, to: documentsURL)
                try fileManager.setAttributes(
                    [FileAttributeKey.posixPermissions: 0o444], ofItemAtPath: documentsURL.path
                )
            } catch {
                logger.error("\(documentsURL.path): \(error.localizedDescription)")
            }
        }
    }
}
