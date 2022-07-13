import AppKit
import AVFoundation
import AVKit
import SwiftUI

class ProjectorViewModel: ObservableObject {
    @Published var projectorViewData: ProjectorViewData = .init(title: "?", primaryText: "?", secondaryText: "?")
}

struct ProjectorViewData {
    let title: String
    let primaryText: String
    let secondaryText: String
}

struct ProjectorView: View {
    @EnvironmentObject var projectorViewModel: ProjectorViewModel

    @Binding var windowOpened: Bool
    @AppStorage("fontSizeVerse") private var fontSizeVerse = 200
    @AppStorage("fontSizeVerseRef") private var fontSizeVerseRef = 20.0
    @AppStorage("vStackPadding") private var vStackPadding = 20.0

    var body: some View {
        HStack {
            Spacer()
            VStack {
                Spacer()
                Text(projectorViewModel.projectorViewData.primaryText)
                Text(projectorViewModel.projectorViewData.title)
                    .padding()
                    .minimumScaleFactor(0.1)
                    .lineLimit(1)
                    .font(.system(size: CGFloat(fontSizeVerseRef), weight: .bold))
                Text(projectorViewModel.projectorViewData.secondaryText)
                Spacer()
            }
            .minimumScaleFactor(0.1).lineLimit(10)
            .font(.system(size: CGFloat(fontSizeVerse), weight: .heavy))
            .layoutPriority(1)
            .padding(vStackPadding)
            Spacer()
        }
        .onDisappear {
            windowOpened = false
        }
        .onAppear {
            windowOpened = true
        }
        .border(.red)
        .multilineTextAlignment(.center)
    }
}
