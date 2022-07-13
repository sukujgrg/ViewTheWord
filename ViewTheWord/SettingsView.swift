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
            FontSettingsView()
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
        VStack {
            Button("Clear History") {
                history.removeAll()
            }
        }.padding(1)
    }
}

struct FontSettingsView: View {
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

            HStack {
                Picker(selection: $primaryBibleName, label: Text("Primary")) {
                    ForEach(bibleUrls(), id: \.absoluteString) { name in
                        Text(String(name.lastPathComponent))
                    }
                }.onChange(of: primaryBibleName) { name in
                    primaryBibleName = name
                }
                Divider()
                Picker(selection: $secondaryBibleName, label: Text("Secondary")) {
                    ForEach(bibleUrls(), id: \.absoluteString) { name in
                        Text(name.lastPathComponent)
                    }
                }.onChange(of: secondaryBibleName) { name in
                    secondaryBibleName = name
                }
            }
            .pickerStyle(.radioGroup)
        }
    }

    func bibleUrls() -> [URL] {
        let bibleUrl = BibleUrl()
        return bibleUrl.getAvailableBibleUrls()
    }

    func importBibleDb(selectedFile: URL) {
        let fileManager = FileManager.default
        let bundledBible = [bundledPrimaryBibleUrl.lastPathComponent, bundledSecondaryBibleUrl.lastPathComponent]
        if bundledBible.contains(selectedFile.lastPathComponent) {
            let documentsURL = fileManager.urls(
                for: .documentDirectory, in: .userDomainMask
            )[0].appendingPathComponent(selectedFile.lastPathComponent)
            do {
                try fileManager.copyItem(at: selectedFile, to: documentsURL)
                try fileManager.setAttributes(
                    [FileAttributeKey.posixPermissions: 0o444], ofItemAtPath: documentsURL.path
                )
            } catch {
                logger.error("\(error.localizedDescription)")
            }
        }
    }
}

struct BibleSelectView: View {
    var body: some View {
        Menu {
            ForEach(1 ... 5, id: \.self) {
                Text("\($0)")
                Divider()
            }
        } label: {
            Image(systemName: "bookmark.circle")
                .resizable()
                .frame(width: 24.0, height: 24.0)
        }
    }
}
