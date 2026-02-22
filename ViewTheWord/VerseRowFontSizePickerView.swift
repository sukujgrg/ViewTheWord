import SwiftUI

struct VerseRowFontSizePickerView: View {
    @Binding var fontSize: Double

    private let options: [Double] = [14, 16, 17, 18, 20, 22, 24]

    var body: some View {
        Picker("Verse row text size", selection: $fontSize) {
            ForEach(options, id: \.self) { size in
                Text("\(Int(size)) pt")
                    .tag(size)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 84)
        .help("Verse row text size")
        .accessibilityLabel("Verse row text size")
    }
}
