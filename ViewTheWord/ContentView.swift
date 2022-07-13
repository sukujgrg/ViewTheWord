import Foundation
import SQLite3
import SwiftUI

struct VerseQuery {
    let bookName: String
    let chapterNumber: Int
    let verseNumber: Int

    func title() -> String {
        return "\(bookName) \(chapterNumber): \(verseNumber)"
    }
}

class VerseTargetModel: ObservableObject {
    @Published var verseQuery: VerseQuery = .init(bookName: "John", chapterNumber: 3, verseNumber: 16)
}

struct ContentView: View {
    @StateObject var verseTargetModel: VerseTargetModel = .init()

    var body: some View {
        MainView().environmentObject(verseTargetModel)
    }
}

struct MainView: View {
    @EnvironmentObject var verseTargetModel: VerseTargetModel
    @StateObject var verseRowViewModel: VerseRowViewModel = .init()
    @StateObject var projectorViewModel: ProjectorViewModel = .init()

    @State private var ask: String = ""
    @State var windowOpened = false
    @State var isShowing = false
    @State private var error: String?

    @AppStorage("history") private var history: [String] = ["John 3: 16"]

    let columns = [
        GridItem(.fixed(50)),
        GridItem(.flexible()),
    ]

    var body: some View {
        NavigationView {
            VStack {
                List {
                    Section(header: Text("History")) {
                        ForEach(history.reversed(), id: \.self) { item in
                            Button(item) {
                                ask = item
                                setWord()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .frame(width: 170, alignment: .leading)
            VStack {
                Button(action: closeProjector) {
                    Text("Clear")
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)

                HStack(alignment: .top) {
                    TextField("John 3 16", text: $ask)
                        .onSubmit {
                            setWord()
                        }
                        .frame(width: 400, height: 35, alignment: .center)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray, lineWidth: 1))
                        .font(.largeTitle)
                }
                VerseRowView(windowOpened: $windowOpened)
                    .environmentObject(projectorViewModel)
                    .environmentObject(verseTargetModel)
                    .environmentObject(verseRowViewModel)
                Spacer()
            }
            .frame(minWidth: 850, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        }
    }

    func setWord() {
        let bibleUrl = BibleUrl()
        let biblePrimary = Bible(dbUrl: bibleUrl.primaryBibleUrl)
        let bibleSecondary = Bible(dbUrl: bibleUrl.secondaryBibleUrl)
        guard let verseQuery = SearchQuery(ask: ask).verseQuery() else {
            return
        }
        verseTargetModel.verseQuery = verseQuery // Observable

        // Set verse for projector view
        let title: String = verseQuery.title()
        var primaryText = "?"
        var secondaryText = "?"

        if let verseOne = biblePrimary.pickAVerse(verseQuery: verseQuery) {
            primaryText = verseOne.verse
        }
        if let verseTwo = bibleSecondary.pickAVerse(verseQuery: verseQuery) {
            secondaryText = verseTwo.verse
        }

        if history.count > 22 {
            history.remove(at: 1)
        }
        if !history.contains(title) && primaryText != "?" {
            history.append(title)
        }
        projectorViewModel.projectorViewData = ProjectorViewData(
            title: title, primaryText: primaryText, secondaryText: secondaryText
        )
        openProjector()

        // Set verse for row view
        guard let chapterA = biblePrimary.pickAChapter(verseQuery: verseQuery) else {
            return
        }
        guard let chapterB = bibleSecondary.pickAChapter(verseQuery: verseQuery) else {
            return
        }
        verseRowViewModel.verseRowData = VerseRowData(chapterA: chapterA, chapterB: chapterB)
    }

    func openProjector() {
        if !windowOpened && projectorViewModel.projectorViewData.primaryText != "?" {
            ProjectorView(windowOpened: $windowOpened)
                .environmentObject(projectorViewModel)
                .openNewWindow(with: "Projector")
        }
    }

    func closeProjector() {
        windowOpened = false
        NSApplication.shared.windows.first(where: { $0.title == "Projector" })?.close()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

