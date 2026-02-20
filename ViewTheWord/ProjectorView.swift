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
    @AppStorage(AppDefaultsKey.projectorTextAlignment) private var projectorTextAlignmentRaw = ProjectorTextAlignmentMode.center.rawValue
    @AppStorage(AppDefaultsKey.projectorReadingDirection) private var projectorReadingDirectionRaw = ProjectorReadingDirectionMode.auto.rawValue

    private var projectorTextAlignmentMode: ProjectorTextAlignmentMode {
        ProjectorTextAlignmentMode(rawValue: projectorTextAlignmentRaw) ?? .center
    }

    private var projectorReadingDirectionMode: ProjectorReadingDirectionMode {
        ProjectorReadingDirectionMode(rawValue: projectorReadingDirectionRaw) ?? .auto
    }

    private var resolvedLayoutDirection: LayoutDirection {
        switch projectorReadingDirectionMode {
        case .auto:
            return inferredLayoutDirection(from: [
                projectorViewModel.projectorViewData.primaryText,
                projectorViewModel.projectorViewData.secondaryText ?? ""
            ].joined(separator: " "))
        case .leftToRight:
            return .leftToRight
        case .rightToLeft:
            return .rightToLeft
        }
    }

    private var resolvedTextAlignment: TextAlignment {
        switch projectorTextAlignmentMode {
        case .left:
            return resolvedLayoutDirection == .leftToRight ? .leading : .trailing
        case .center:
            return .center
        case .right:
            return resolvedLayoutDirection == .leftToRight ? .trailing : .leading
        }
    }

    private var resolvedFrameAlignment: Alignment {
        switch projectorTextAlignmentMode {
        case .left:
            return .leading
        case .center:
            return .center
        case .right:
            return .trailing
        }
    }

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                Text(projectorViewModel.projectorViewData.primaryText)
                    .font(.system(size: CGFloat(fontSizeVerse), weight: .heavy))
                    .minimumScaleFactor(0.1)
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: resolvedFrameAlignment)

                Text(projectorViewModel.projectorViewData.title)
                    .padding(.vertical, 4)
                    .minimumScaleFactor(0.1)
                    .lineLimit(1)
                    .font(.system(size: CGFloat(fontSizeVerseRef), weight: .bold))
                    .frame(maxWidth: .infinity, alignment: resolvedFrameAlignment)

                if let secondaryText = projectorViewModel.projectorViewData.secondaryText, secondaryText != "\u{200c}" {
                    Text(secondaryText)
                        .font(.system(size: CGFloat(fontSizeVerse), weight: .heavy))
                        .minimumScaleFactor(0.1)
                        .lineLimit(10)
                        .frame(maxWidth: .infinity, alignment: resolvedFrameAlignment)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(vStackPadding)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, resolvedLayoutDirection)
        .multilineTextAlignment(resolvedTextAlignment)
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
    }

    private func inferredLayoutDirection(from text: String) -> LayoutDirection {
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || CharacterSet.symbols.contains(scalar) {
                continue
            }

            return isRightToLeftScalar(scalar) ? .rightToLeft : .leftToRight
        }

        return .leftToRight
    }

    private func isRightToLeftScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value

        return (0x0590...0x08FF).contains(value) // Hebrew, Arabic and related scripts.
            || (0xFB1D...0xFDFF).contains(value) // Hebrew/Arabic presentation forms.
            || (0xFE70...0xFEFF).contains(value) // Arabic presentation forms-B.
            || (0x10800...0x10FFF).contains(value) // Cypriot, Imperial Aramaic and other historic RTL ranges.
    }
}
