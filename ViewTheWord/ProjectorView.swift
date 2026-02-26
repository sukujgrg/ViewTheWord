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
    @Published private(set) var projectorViewData: ProjectorViewData = .init(
        title: "?",
        primaryText: "?",
        secondaryText: "?",
        primaryTranslationName: "",
        secondaryTranslationName: nil
    )
    @Published private(set) var projectionOwner: ProjectionOwner?

    func project(_ data: ProjectorViewData, owner: ProjectionOwner) {
        projectorViewData = data
        projectionOwner = owner
    }

    func clearProjection() {
        projectorViewData = .init(
            title: "?",
            primaryText: "?",
            secondaryText: "?",
            primaryTranslationName: "",
            secondaryTranslationName: nil
        )
        projectionOwner = nil
    }
}

struct ProjectorViewData {
    let title: String
    let primaryText: String
    let secondaryText: String?
    let primaryTranslationName: String
    let secondaryTranslationName: String?
}

struct ProjectorView: View {
    @EnvironmentObject var projectorViewModel: ProjectorViewModel

    @Binding var windowOpened: Bool
    @AppStorage("fontSizeVerse") private var fontSizeVerse = 200.0
    @AppStorage("fontSizeVerseRef") private var fontSizeVerseRef = 36.0
    @AppStorage("vStackPadding") private var vStackPadding = 20.0
    @AppStorage(AppDefaultsKey.projectorTextAlignment) private var projectorTextAlignmentRaw = ProjectorTextAlignmentMode.center.rawValue
    @AppStorage(AppDefaultsKey.projectorReadingDirection) private var projectorReadingDirectionRaw = ProjectorReadingDirectionMode.auto.rawValue
    @AppStorage(AppDefaultsKey.projectorDualLayoutVertical) private var projectorDualLayoutVertical = false

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

    private var secondaryVerseText: String? {
        guard let secondaryText = projectorViewModel.projectorViewData.secondaryText,
              secondaryText != "\u{200c}" else {
            return nil
        }

        return secondaryText
    }

    private var translationInfoText: String {
        let orderedNames = orderedTranslationNames.compactMap { name in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedName.isEmpty ? nil : trimmedName
        }

        return orderedNames.joined(separator: " ↔ ")
    }

    private var orderedTranslationNames: [String] {
        let primaryName = projectorViewModel.projectorViewData.primaryTranslationName
        guard let secondaryVerseText,
              !secondaryVerseText.isEmpty,
              let secondaryName = projectorViewModel.projectorViewData.secondaryTranslationName
        else {
            return [primaryName]
        }

        if projectorDualLayoutVertical {
            return [primaryName, secondaryName]
        }

        if resolvedLayoutDirection == .leftToRight {
            return [primaryName, secondaryName]
        }

        return [secondaryName, primaryName]
    }

    private var referenceTitleText: some View {
        Text(projectorViewModel.projectorViewData.title)
            .foregroundStyle(Color.accentColor.opacity(0.95))
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    private var translationInfoLabelText: some View {
        Text(translationInfoText)
            .foregroundStyle(Color.teal.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private var referenceLineView: some View {
        let translationInfoText = translationInfoText
        if translationInfoText.isEmpty {
            referenceTitleText
                .frame(maxWidth: .infinity, alignment: resolvedFrameAlignment)
        } else if resolvedLayoutDirection == .leftToRight {
            HStack(spacing: 14) {
                referenceTitleText
                    .frame(maxWidth: .infinity, alignment: .leading)

                translationInfoLabelText
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(spacing: 14) {
                translationInfoLabelText
                    .frame(maxWidth: .infinity, alignment: .leading)

                referenceTitleText
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            referenceLineView
                .font(.system(size: CGFloat(fontSizeVerseRef), weight: .bold))
                .padding(.bottom, 16)

            Spacer(minLength: 0)

            verseContent

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(vStackPadding)
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, resolvedLayoutDirection)
        .multilineTextAlignment(resolvedTextAlignment)
        .onDisappear {
            windowOpened = false
            projectorViewModel.clearProjection()
        }
    }

    @ViewBuilder
    private var verseContent: some View {
        if let secondaryVerseText {
            if projectorDualLayoutVertical {
                VStack(spacing: 18) {
                    verseText(projectorViewModel.projectorViewData.primaryText)
                    dualLayoutDivider
                        .padding(.horizontal, 12)
                    verseText(secondaryVerseText)
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    verseText(projectorViewModel.projectorViewData.primaryText)
                    dualLayoutDivider
                        .frame(width: 2)
                        .padding(.vertical, 8)
                    verseText(secondaryVerseText)
                }
            }
        } else {
            verseText(projectorViewModel.projectorViewData.primaryText)
        }
    }

    private var dualLayoutDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.26))
    }

    private func verseText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: CGFloat(fontSizeVerse), weight: .heavy))
            .minimumScaleFactor(0.1)
            .lineLimit(10)
            .frame(maxWidth: .infinity, alignment: resolvedFrameAlignment)
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
