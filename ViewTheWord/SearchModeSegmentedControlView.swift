import SwiftUI

struct SearchModeSegmentedControlView: View {
    @Binding var searchMode: SearchMode

    var body: some View {
        Picker("Search mode", selection: $searchMode) {
            Text("Ref")
                .help("Reference search: book/chapter/verse")
                .tag(SearchMode.verseReference)

            Text("Words")
                .help("Word search across verses")
                .tag(SearchMode.wordSearch)

            Text("Phrase")
                .help("Phrase search across verses")
                .tag(SearchMode.phraseSearch)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 220)
        .help("Search mode: Ref (book/chapter/verse), Words (word search), Phrase (phrase search)")
        .accessibilityLabel("Search mode")
    }
}
