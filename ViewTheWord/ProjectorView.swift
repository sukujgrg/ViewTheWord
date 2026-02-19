import SwiftUI

enum ProjectionOwner {
    case textInputTarget(VerseReference)
    case verseRowSelection(VerseReference)
    case searchResult(VerseReference)
}

extension ProjectionOwner: Equatable {
    static func == (lhs: ProjectionOwner, rhs: ProjectionOwner) -> Bool {
        switch (lhs, rhs) {
        case (.textInputTarget(let left), .textInputTarget(let right)):
            return left == right
        case (.verseRowSelection(let left), .verseRowSelection(let right)):
            return left == right
        case (.searchResult(let left), .searchResult(let right)):
            return left == right
        default:
            return false
        }
    }
}

class ProjectorViewModel: ObservableObject {
    @Published private(set) var projectorViewData: ProjectorViewData = .init(title: "?", primaryText: "?", secondaryText: "?")
    @Published private(set) var projectionOwner: ProjectionOwner?

    func project(_ data: ProjectorViewData, owner: ProjectionOwner) {
        projectorViewData = data
        projectionOwner = owner
    }

    func clearProjection() {
        projectorViewData = .init(title: "?", primaryText: "?", secondaryText: "?")
        projectionOwner = nil
    }
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
            windowOpened = false
            clearApi()
            projectorViewModel.clearProjection()
        }
        .onChange(of: projectorViewModel.projectorViewData.title) { _, _ in
            // Only send if we have valid data (not placeholder)
            if projectorViewModel.projectorViewData.primaryText != "?" {
                sendTextOverNetwork(text: projectorViewModel.projectorViewData.primaryText, title: projectorViewModel.projectorViewData.title)
            }
        }
        .multilineTextAlignment(.center)
    }
}
