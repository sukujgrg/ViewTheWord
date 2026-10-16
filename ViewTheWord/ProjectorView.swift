import SwiftUI

@MainActor
final class NativeOutputRenderModel: ObservableObject {
    @Published var profile: NativeOutputProfile
    init(profile: NativeOutputProfile) { self.profile = profile }
}

/// A pure rendering of committed scripture and one appearance profile.
struct NativeOutputView: View {
    @ObservedObject var appearance: NativeOutputRenderModel
    var body: some View { ProjectorView(profile: appearance.profile) }
}

/// Matches eucaly's native Confidence clock, independent of scripture styling.
struct OutputStandbyClock: View {
    let size: CGSize
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let calendar = Calendar.autoupdatingCurrent
            let clock = String(format: "%02d:%02d", calendar.component(.hour, from: context.date), calendar.component(.minute, from: context.date))
            Text(clock)
                .font(.system(size: max(1, min(size.width * 0.23, size.height * 0.45)), weight: .heavy, design: .rounded))
                .monospacedDigit().foregroundStyle(Color(red: 1, green: 0.82, blue: 0.24))
                .lineLimit(1).minimumScaleFactor(0.1)
                .padding(min(32, max(0, size.height * 0.04)))
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Clock").accessibilityValue(clock)
                .frame(width: size.width, height: size.height, alignment: .center)
        }
    }
}

struct ProjectorView: View {
    @EnvironmentObject var projectorViewModel: ProjectorViewModel
    var profile: NativeOutputProfile = .audience
    private var components: OutputScriptureComponents { profile.components(in: projectorViewModel.projectorViewData) }
    private var isStandby: Bool { projectorViewModel.projection == nil || projectorViewModel.isBlanked }
    private var resolvedLayoutDirection: LayoutDirection {
        switch profile.readingDirection {
        case .auto: return inferredLayoutDirection(from: [components.primary, components.secondary].compactMap { $0 }.joined(separator: " "))
        case .leftToRight: return .leftToRight
        case .rightToLeft: return .rightToLeft
        }
    }
    private var resolvedTextAlignment: TextAlignment {
        switch profile.alignment {
        case .left: return resolvedLayoutDirection == .leftToRight ? .leading : .trailing
        case .center: return .center
        case .right: return resolvedLayoutDirection == .leftToRight ? .trailing : .leading
        }
    }
    private var resolvedFrameAlignment: Alignment {
        switch profile.alignment { case .left: .leading; case .center: .center; case .right: .trailing }
    }
    private var names: String {
        var names = [components.primaryName, components.secondaryName].compactMap { $0 }.filter { !$0.isEmpty }
        if profile.translationLayout == .horizontal, resolvedLayoutDirection == .rightToLeft { names.reverse() }
        return names.joined(separator: " • ")
    }
    private var referenceTitle: some View {
        Text(components.reference ?? "")
            .font(Font(profile.reference.font()))
            .foregroundStyle(Color(nsColor: profile.referenceColor.nsColor))
            .lineLimit(1).minimumScaleFactor(0.5).truncationMode(.tail).layoutPriority(1)
    }
    private var translationNames: some View {
        Text(names).font(Font(profile.translationNames.font()))
            .foregroundStyle(Color(nsColor: profile.translationNamesColor.nsColor))
            .lineLimit(1).minimumScaleFactor(0.5).truncationMode(.tail)
    }
    @ViewBuilder private var referenceLine: some View {
        if names.isEmpty { referenceTitle.frame(maxWidth: .infinity, alignment: resolvedFrameAlignment) }
        else if components.reference == nil { translationNames.frame(maxWidth: .infinity, alignment: resolvedFrameAlignment) }
        else if resolvedLayoutDirection == .leftToRight {
            HStack(spacing: 14) {
                referenceTitle.frame(maxWidth: .infinity, alignment: .leading)
                translationNames.frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            HStack(spacing: 14) {
                translationNames.frame(maxWidth: .infinity, alignment: .leading)
                referenceTitle.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let contentHeight = geometry.size.height * (profile.placement == .lowerThird ? 0.3 : 1)
            let padding = min(max(0, profile.padding), min(geometry.size.width, contentHeight) * 0.22)
            ZStack {
                if !profile.transparent { Color(nsColor: profile.background.nsColor) }
                if isStandby, profile.standby == .clock {
                    OutputStandbyClock(size: geometry.size).environment(\.layoutDirection, .leftToRight)
                } else if !isStandby {
                    VStack(spacing: 16) {
                        if components.reference != nil || !names.isEmpty {
                            referenceLine.frame(height: min(max(profile.reference.size, profile.translationNames.size) * 1.3, contentHeight * 0.16))
                        }
                        verseContent
                    }
                    .padding(padding)
                    .frame(height: contentHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: profile.placement == .lowerThird ? .bottom : .center)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .environment(\.layoutDirection, resolvedLayoutDirection)
        .multilineTextAlignment(resolvedTextAlignment)
        .accessibilityHidden(isStandby && profile.standby != .clock)
    }
    @ViewBuilder private var verseContent: some View {
        if let primary = components.primary, let secondary = components.secondary {
            if profile.translationLayout == .vertical {
                VStack(spacing: 18) {
                    verseText(primary, color: profile.primaryColor)
                    divider.padding(.horizontal, 12)
                    verseText(secondary, color: profile.secondaryColor)
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    verseText(primary, color: profile.primaryColor)
                    divider.frame(width: 2).padding(.vertical, 8)
                    verseText(secondary, color: profile.secondaryColor)
                }
            }
        } else if let primary = components.primary { verseText(primary, color: profile.primaryColor) }
        else if let secondary = components.secondary { verseText(secondary, color: profile.secondaryColor) }
        else { Spacer(minLength: 0) }
    }
    private var divider: some View { Divider().overlay(Color(nsColor: profile.primaryColor.nsColor).opacity(0.26)) }
    private func verseText(_ text: String, color: OutputColor) -> some View {
        GeometryReader { geometry in
            let size = ProjectorTextLayout.fontSize(for: text, in: geometry.size, typography: profile.verse)
            ViewThatFits(in: .vertical) {
                ForEach([1.0, 0.95, 0.9, 0.8, 0.65, 0.5, 0.25], id: \.self) { scale in
                    Text(text).font(Font(profile.verse.font(size: max(1, size * scale))))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Color(nsColor: color.nsColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: resolvedFrameAlignment)
            .environment(\.layoutDirection, profile.readingDirection == .auto ? inferredLayoutDirection(from: text) : resolvedLayoutDirection)
        }
    }
    private func inferredLayoutDirection(from text: String) -> LayoutDirection {
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar) || CharacterSet.symbols.contains(scalar) { continue }
            let value = scalar.value
            let rtl = (0x0590...0x08FF).contains(value) || (0xFB1D...0xFDFF).contains(value)
                || (0xFE70...0xFEFF).contains(value) || (0x10800...0x10FFF).contains(value)
            return rtl ? .rightToLeft : .leftToRight
        }
        return .leftToRight
    }
}
