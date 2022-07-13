import SwiftUI

class VerseRowViewModel: ObservableObject {
    @Published var verseRowData: VerseRowData = .init(chapterA: [], chapterB: [])
}

struct VerseRowData: Identifiable {
    let id: UUID = .init()
    let chapterA: [AVerse]
    let chapterB: [AVerse]
}

struct VerseRowView: View {
    @EnvironmentObject var verseTargetModel: VerseTargetModel
    @EnvironmentObject var verseRowViewModel: VerseRowViewModel
    @EnvironmentObject var projectorViewModel: ProjectorViewModel

    @State private var clickedVerse: Int = 0
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
                ForEach(0 ..< verseRowViewModel.verseRowData.chapterA.count, id: \.self) { index in
                    // Primary verse
                    Text(verseRowViewModel.verseRowData.chapterA[index].verse)
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
                    Text(verseRowViewModel.verseRowData.chapterB[index].verse)
                }
            }
            .padding(.horizontal)
        }
        .frame(maxHeight: 800)
    }

    func project(index: Int) {
        let title = verseTargetModel.verseQuery.title()
        let primaryText = verseRowViewModel.verseRowData.chapterA[index].verse
        let secondaryText = verseRowViewModel.verseRowData.chapterB[index].verse
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
