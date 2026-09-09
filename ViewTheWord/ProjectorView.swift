import SwiftUI

struct ProjectorView: View {
    @EnvironmentObject var projectorViewModel: ProjectorViewModel

    @AppStorage(AppDefaultsKey.fontSizeVerse) private var fontSizeVerse = AppDefaults.verseFontSize
    @AppStorage(AppDefaultsKey.fontSizeVerseRef) private var fontSizeVerseRef = AppDefaults.referenceFontSize
    @AppStorage(AppDefaultsKey.projectorPadding) private var vStackPadding = AppDefaults.projectorPadding
    @AppStorage(AppDefaultsKey.projectorTextAlignment) private var projectorTextAlignmentRaw = ProjectorTextAlignmentMode.center.rawValue
    @AppStorage(AppDefaultsKey.projectorReadingDirection) private var projectorReadingDirectionRaw = ProjectorReadingDirectionMode.auto.rawValue
    @AppStorage(AppDefaultsKey.projectorDualLayoutVertical) private var projectorDualLayoutVertical = false
    @AppStorage(AppDefaultsKey.projectorShowTranslationInfo) private var projectorShowTranslationInfo = true

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
        guard projectorShowTranslationInfo else {
            return ""
        }

        let orderedNames = orderedTranslationNames.compactMap { name in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedName.isEmpty ? nil : trimmedName
        }

        return orderedNames.joined(separator: " • ")
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
        GeometryReader { geometry in
            let padding = min(max(0, vStackPadding), min(geometry.size.width, geometry.size.height) * 0.22)
            VStack(spacing: 16) {
                referenceLineView
                    .font(.system(size: CGFloat(fontSizeVerseRef), weight: .bold))
                    .minimumScaleFactor(0.5)
                    .frame(height: min(CGFloat(fontSizeVerseRef) * 1.3, geometry.size.height * 0.16))
                verseContent
            }
            .padding(padding)
            .opacity(projectorViewModel.isBlanked ? 0 : 1)
        }
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, resolvedLayoutDirection)
        .multilineTextAlignment(resolvedTextAlignment)
        .accessibilityHidden(projectorViewModel.isBlanked)
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
        GeometryReader { geometry in
            let size = ProjectorTextLayout.fontSize(for: text, in: geometry.size, preferred: fontSizeVerse)
            // Font fallback and leading can differ between AppKit measurement
            // and SwiftUI rendering. Verify the natural height in SwiftUI too.
            ViewThatFits(in: .vertical) {
                ForEach([1.0, 0.95, 0.9, 0.8, 0.65, 0.5, 0.25], id: \.self) { scale in
                    Text(text)
                        .font(.system(size: max(1, size * scale), weight: .heavy))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: resolvedFrameAlignment)
            .environment(\.layoutDirection, projectorReadingDirectionMode == .auto ? inferredLayoutDirection(from: text) : resolvedLayoutDirection)
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
