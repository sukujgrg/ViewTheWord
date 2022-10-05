import Foundation
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
    @State private var sideAsk: String = ""
    @State private var windowOpened = false
    @State private var validQuery = true
    @State private var chapterCount: Int32 = 0

    @AppStorage("history") private var history: [String] = ["John 3: 16"]
    @AppStorage("showOnlyPrimary") var showOnlyPrimary = false

    // To reload the VerseRowView and ProjectorView if the bible changes in Settings.
    @AppStorage("PrimaryBibleName") private var primaryBibleName: String = bundledPrimaryBibleUrl.absoluteString
    @AppStorage("SecondaryBibleName") private var secondaryBibleName: String = bundledSecondaryBibleUrl.absoluteString

    var body: some View {
        NavigationView {
            VStack {
                HStack{
                    List {
                        Section(header: Text("Books")) {
                            ForEach(bibleBooks.keys, id: \.self) { item in
                                if item == "Psalm" { Divider() }
                                Button(action: { getChapterCount(ask: item)}) {
                                    Text(item)
                                }
                                .font(.body)
                                .buttonStyle(.borderless)
                                .background(
                                    Color(
                                        sideAsk == item ? lemonYellow : .clear
                                    )
                                )
                            }
                        }
                    }
                    .frame(width: 190, alignment: .leading)
                    List {
                        if chapterCount > 0 {
                            ForEach(1...chapterCount, id: \.self) { i in
                                Button(String(i)) {
                                    ask = "\(sideAsk) \(String(i))"
                                    setWord(updateRowView: true)
                                }
                                .font(.body)
                                .buttonStyle(.borderless)
                                .background(
                                    Color(
                                        ask == "\(sideAsk) \(String(i))" ? lemonYellow : .clear
                                    )
                                )
                            }
                        }
                    }
                    .frame(width: 90, alignment: .center)
                }
            }
            .frame(width: 270, alignment: .leading)
            VStack {
                Button(action: closeProjector) {
                    Text("Clear")
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                HStack(alignment: .center) {

                    TextField("John 3 16", text: $ask)
                        .onSubmit {
                            setWord()
                            withAnimation(.default) {
                                validQuery = true  // resetting to 'true'
                            }
                        }
                        .onChange(of: primaryBibleName, perform: { _ in setWord()}) // reload primary bible verse[s]
                        .onChange(of: secondaryBibleName, perform: { _ in setWord()}) // reload secondary bible verse[s]
                        .modifier(ShakeEffect(shakes: validQuery ? 2 : 0))
                        .frame(width: 450, height: 35, alignment: .center)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray, lineWidth: 1))
                        .font(.largeTitle)
                        .disableAutocorrection(true)
                    VStack {
                        Menu("OT") {
                            ForEach(bibleBooks.keys[..<39], id: \.self) { item in
                                if item == "Psalm" { Divider() }
                                Button(item) { ask = item }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        Menu("NT") {
                            ForEach(bibleBooks.keys[39...], id: \.self) { item in
                                Button(item) { ask = item }
                            }
                        }
                        .menuStyle(.borderlessButton)
                    }
                    .frame(width: 50)

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

    func getChapterCount(ask: String) {
        sideAsk = ask
        let bibleUrl = BibleUrl()
        let biblePrimary = Bible(dbUrl: bibleUrl.primaryBibleUrl)
        let count = biblePrimary.getChapterCount(bookName: ask)
        chapterCount = count ?? 0
    }
    
    func setWord(updateRowView: Bool = true) {
        guard let verseQuery = SearchQuery(ask: ask).verseQuery() else {
            validQuery.toggle()
            return
        }

        let bibleUrl = BibleUrl()
        let biblePrimary = Bible(dbUrl: bibleUrl.primaryBibleUrl)
        let bibleSecondary = Bible(dbUrl: bibleUrl.secondaryBibleUrl)

        // Primary
        var primaryText = "?"
        if let verseOne = biblePrimary.pickAVerse(verseQuery: verseQuery) {
            primaryText = verseOne.verse
        } else {
            validQuery.toggle()
            return
        }

        // Secondary
        var secondaryText: String?
        if !showOnlyPrimary {
            if let verseTwo = bibleSecondary.pickAVerse(verseQuery: verseQuery) {
                secondaryText = verseTwo.verse
            }
        }

        // Title
        let title: String = verseQuery.title()

        // History
        if history.count > 22 {
            history.remove(at: 1)
        }
        if !history.contains(title) && primaryText != "?" {
            history.append(title)
        }

        if primaryText != "?" {
            // Set verse for projector view
            projectorViewModel.projectorViewData = ProjectorViewData(
                title: title, primaryText: primaryText, secondaryText: secondaryText
            )
            openProjector()
        }

        // Row view needs to set/update only when `ask` is via TextField.
        if updateRowView {
            verseTargetModel.verseQuery = verseQuery // Observable

            // Resetting TextField content
            ask = title

            // Set verse for row view
            guard let primaryChapter = biblePrimary.pickAChapter(verseQuery: verseQuery) else {
                return
            }
            guard let secondaryChapter = bibleSecondary.pickAChapter(verseQuery: verseQuery) else {
                return
            }
            verseRowViewModel.verseRowData = VerseRowData(
                primaryChapter: primaryChapter, secondaryChapter: secondaryChapter
            )
        }
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

struct ShakeEffect: GeometryEffect {
    func effectValue(size: CGSize) -> ProjectionTransform {
        return ProjectionTransform(
            CGAffineTransform(translationX: -30 * sin(position * 2 * .pi), y: 0)
        )
    }

    init(shakes: Int) {
        position = CGFloat(shakes)
    }

    var position: CGFloat
    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
