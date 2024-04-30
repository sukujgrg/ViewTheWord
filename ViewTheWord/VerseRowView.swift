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
    @AppStorage("scrollTo") var scrollTo = true

    @AppStorage("PrimaryBibleName") private var primaryBibleName: String = bundledPrimaryBibleUrl.absoluteString
    @AppStorage("SecondaryBibleName") private var secondaryBibleName: String = bundledSecondaryBibleUrl.absoluteString

    @State private var currentIndex: Int = -1

    @Binding var windowOpened: Bool

    let columns = [
        GridItem(.flexible()),
        GridItem(.fixed(60)),
        GridItem(.flexible())
    ]

    var body: some View {
        if verseRowViewModel.verseRowData.primaryChapter.count > 0 {
            let pb = primaryBibleName.components(separatedBy: "/").last
            let sb = secondaryBibleName.components(separatedBy: "/").last
            let pri = verseRowViewModel.verseRowData.primaryChapter
            Grid {
                Divider()
                GridRow {
                    Text("\(pb?.replacingOccurrences(of: ".bible", with: "").replacingOccurrences(of: "_", with: " ") ?? "")")
                    Text("\(pri[0].bookName) \(pri[0].chapterNumber)")
                    Text("\(sb?.replacingOccurrences(of: ".bible", with: "").replacingOccurrences(of: "_", with: " ") ?? "")")
                }
                Divider()
            }
        }
        ScrollView {
            ScrollViewReader { value in
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    let count = max(verseRowViewModel.verseRowData.primaryChapter.count, verseRowViewModel.verseRowData.secondaryChapter.count)
                    ForEach(0 ..< count, id: \.self) { index in

                        // Primary verse
                        if index < verseRowViewModel.verseRowData.primaryChapter.count {
                            Text(verseRowViewModel.verseRowData.primaryChapter[index].verse)
                                .onTapGesture(perform: { project(index: index) })
                                .padding()
                                .background(
                                    Color(
                                        projectorViewModel.projectorViewData.title == verseTargetModel.verseQuery.title() && windowOpened == true && currentIndex == index ? .systemBlue : .clear
                                    )
                                )
                        } else {
                            Text("\u{200c}")
                        }

                        // Verse button
                        Button(action: { project(index: index) }) {
                            Text(String(index + 1))
                                .frame(width: 60, height: 60)
                                .background(
                                    Color(
                                        projectorViewModel.projectorViewData.title == verseTargetModel.verseQuery.title() && windowOpened == true && currentIndex == index ? .systemBlue : .gray
                                    )
                                )
                                .foregroundColor(.white)
                        }
                        .buttonStyle(PlainButtonStyle())

                        // Secondary verse
                        if index < verseRowViewModel.verseRowData.secondaryChapter.count {
                            Text(verseRowViewModel.verseRowData.secondaryChapter[index].verse)
                                .onTapGesture(perform: { project(index: index) })
                                .padding()
                                .background(
                                    Color(
                                        projectorViewModel.projectorViewData.title == verseTargetModel.verseQuery.title() && windowOpened == true && currentIndex == index ? .systemBlue : .clear
                                    )
                                )
                        } else {
                            Text("\u{200c}")
                        }
                    }
                    .onChange(of: verseTargetModel.verseQuery.verseNumber) { _ in
                        currentIndex = verseTargetModel.verseQuery.verseNumber - 1
                        if scrollTo {
                            value.scrollTo(currentIndex, anchor: .center)
                        }
                    }
                    // this scroll is needed when switching between books/chapters
                    .onChange(of: verseTargetModel.verseQuery.bookAndChapter()) { _ in
                        currentIndex = verseTargetModel.verseQuery.verseNumber - 1
                        value.scrollTo(currentIndex, anchor: .center)
                    }
                    .onAppear {
                        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { nsevent in
                            let maxSelectionIndex = verseRowViewModel.verseRowData.primaryChapter.count - 1
                            if nsevent.keyCode == 125 { // arrow down
                                if currentIndex >= 0 && currentIndex < maxSelectionIndex {
                                    project(index: currentIndex + 1)
                                }
                            } else if nsevent.keyCode == 126 { // arrow up
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

        var primaryText: String?
        if index < verseRowViewModel.verseRowData.primaryChapter.count {
            primaryText = verseRowViewModel.verseRowData.primaryChapter[index].verse
        }

        var secondaryText: String?
        if !showOnlyPrimary {
            if index < verseRowViewModel.verseRowData.secondaryChapter.count {
                secondaryText = verseRowViewModel.verseRowData.secondaryChapter[index].verse
            }
        }
        projectorViewModel.projectorViewData = ProjectorViewData(
            title: title, primaryText: primaryText ?? "\u{200c}", secondaryText: secondaryText ?? "\u{200c}"
        )
        if !windowOpened {
            ProjectorView(windowOpened: $windowOpened)
                .environmentObject(projectorViewModel)
                .openNewWindow(with: "Projector")
        }
    }
}
