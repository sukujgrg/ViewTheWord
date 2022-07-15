import SwiftUI

class VerseRowViewModel: ObservableObject {
    @Published var verseRowData: VerseRowData = .init(primaryChapter: [], secondaryChapter: [])
}

struct VerseRowData: Identifiable {
    let id: UUID = .init()
    let primaryChapter: [AVerse]
    let secondaryChapter: [AVerse]
}

struct VerseRowView: View {
    @EnvironmentObject var verseTargetModel: VerseTargetModel
    @EnvironmentObject var verseRowViewModel: VerseRowViewModel
    @EnvironmentObject var projectorViewModel: ProjectorViewModel

    @AppStorage("showOnlyPrimary") var showOnlyPrimary = false

    @State private var hoverText = -1

    @Binding var windowOpened: Bool

    let columns = [
        GridItem(.flexible()),
        GridItem(.fixed(60)),
        GridItem(.flexible()),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(0 ..< verseRowViewModel.verseRowData.primaryChapter.count, id: \.self) { index in
                    // Primary verse
                    Text(verseRowViewModel.verseRowData.primaryChapter[index].verse)
                    // Verse button
                    Button(action: { project(index: index) }) {
                        Text(String(index + 1))
                            .frame(width: 60, height: 60)
                            .background(Color(hoverText == index ? .systemBlue : .gray))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHover(perform: { _ in
                        hoverText = index
                    })
                    // Secondary verse
                    Text(verseRowViewModel.verseRowData.secondaryChapter[index].verse)
                }
            }
            .padding(.horizontal)
        }
        .frame(maxHeight: 800)
    }

    func project(index: Int) {
        verseTargetModel.verseQuery = VerseQuery(
            bookName: verseTargetModel.verseQuery.bookName,
            chapterNumber: verseTargetModel.verseQuery.chapterNumber,
            verseNumber: index + 1
        )
        let title = verseTargetModel.verseQuery.title()
        let primaryText = verseRowViewModel.verseRowData.primaryChapter[index].verse
        var secondaryText: String? = nil
        if !showOnlyPrimary {
            secondaryText = verseRowViewModel.verseRowData.secondaryChapter[index].verse
        }
        projectorViewModel.projectorViewData = ProjectorViewData(
            title: title, primaryText: primaryText, secondaryText: secondaryText
        )
        if !windowOpened {
            ProjectorView(windowOpened: $windowOpened)
                .environmentObject(projectorViewModel)
                .openNewWindow(with: "Projector")
        }
    }
}
