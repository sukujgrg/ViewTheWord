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
    @State private var currentIndex: Int = 0

    @Binding var windowOpened: Bool

    let columns = [
        GridItem(.flexible()),
        GridItem(.fixed(60)),
        GridItem(.flexible())
    ]

    var body: some View {
        if verseRowViewModel.verseRowData.primaryChapter.count > 0 {
            let pri = verseRowViewModel.verseRowData.primaryChapter
            Text("\(pri[0].bookName) \(pri[0].chapterNumber)")
                .bold()
                .padding()
        }
        ScrollView {
            ScrollViewReader { value in
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(0 ..< verseRowViewModel.verseRowData.primaryChapter.count, id: \.self) { index in
                        // Primary verse
                        Text(verseRowViewModel.verseRowData.primaryChapter[index].verse)
                            .onTapGesture(perform: { project(index: index) })
                            .padding()
                            .onHover(perform: { _ in hoverText = index })

                        // Verse button
                        Button(action: { project(index: index) }) {
                            Text(String(index + 1))
                                .frame(width: 60, height: 60)
                                .background(
                                    Color(
                                        hoverText == index && hoverText != currentIndex ? .systemBlue :
                                            ((currentIndex == index) ? lemonYellow : .gray)
                                    )
                                )
                                .foregroundColor(.black)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onHover(perform: { _ in hoverText = index })

                        // Secondary verse
                        Text(verseRowViewModel.verseRowData.secondaryChapter[index].verse)
                            .onTapGesture(perform: { project(index: index) })
                            .padding()
                            .onHover(perform: { _ in hoverText = index })
                    }
                    .onChange(of: verseTargetModel.verseQuery.verseNumber) { newV in
                        currentIndex = verseTargetModel.verseQuery.verseNumber - 1
                        value.scrollTo(newV - 1, anchor: .center)
                    }
                    .onAppear {
                        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { nsevent in
                            let maxSelectionIndex = verseRowViewModel.verseRowData.primaryChapter.count - 1
                            if nsevent.keyCode == 125 || nsevent.keyCode == 124 { // arrow down or right
                                if currentIndex >= 0 && currentIndex < maxSelectionIndex {
                                    project(index: currentIndex + 1)
                                }
                            } else if nsevent.keyCode == 126 || nsevent.keyCode == 123 { // arrow up or left
                                if currentIndex > 0 && currentIndex <= maxSelectionIndex {
                                    project(index: currentIndex - 1)
                                }
                            }
                            return nsevent
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
        .frame(maxHeight: .infinity)
    }

    private func newVerseTargetModel(index: Int) {
        verseTargetModel.verseQuery = VerseQuery(
            bookName: verseTargetModel.verseQuery.bookName,
            chapterNumber: verseTargetModel.verseQuery.chapterNumber,
            verseNumber: index + 1
        )
    }

    private func project(index: Int) {
        newVerseTargetModel(index: index)
        let title = verseTargetModel.verseQuery.title()
        let primaryText = verseRowViewModel.verseRowData.primaryChapter[index].verse
        var secondaryText: String?
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
