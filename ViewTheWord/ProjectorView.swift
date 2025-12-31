import SwiftUI

class ProjectorViewModel: ObservableObject {
    @Published var projectorViewData: ProjectorViewData = .init(title: "?", primaryText: "?", secondaryText: "?")
}

struct ProjectorViewData {
    let title: String
    let primaryText: String
    let secondaryText: String?
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
                if let secondaryText = projectorViewModel.projectorViewData.secondaryText {
                    if secondaryText != "\u{200c}" {
                        Text(secondaryText)
                    }
                }
                Spacer()
            }
            .minimumScaleFactor(0.1).lineLimit(10)
            .font(.system(size: CGFloat(fontSizeVerse), weight: .heavy))
            .layoutPriority(1)
            .padding(vStackPadding)
            .preferredColorScheme(.dark)
            Spacer()
        }
        .onDisappear {
            // Only update flag if window is actually closed
            DispatchQueue.main.async {
                if !NSApplication.shared.windows.contains(where: { $0.title == "Projector" }) {
                    windowOpened = false
                }
            }
            clearApi()
        }
        .onChange(of: projectorViewModel.projectorViewData.title){
            // Only send if we have valid data (not placeholder)
            if projectorViewModel.projectorViewData.primaryText != "?" {
                sendTextOverNetwork(text: projectorViewModel.projectorViewData.primaryText, title: projectorViewModel.projectorViewData.title)
            }
        }
        .multilineTextAlignment(.center)
    }
}
