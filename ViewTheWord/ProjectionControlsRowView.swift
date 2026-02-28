import SwiftUI

struct ProjectionControlsRowView: View {
    @Binding var transparentBackground: Bool
    @Binding var projectorTextAlignmentRaw: String
    @Binding var projectorReadingDirectionRaw: String
    @Binding var projectorDualLayoutVertical: Bool

    @AppStorage(AppDefaultsKey.projectorScreenDisplayID) private var projectorScreenDisplayID = 0
    @AppStorage(AppDefaultsKey.projectorShowTranslationInfo) private var projectorShowTranslationInfo = true
    @State private var availableScreens: [ScreenOption] = []

    private var projectorAlignmentSelection: Binding<ProjectorTextAlignmentMode> {
        Binding {
            ProjectorTextAlignmentMode(rawValue: projectorTextAlignmentRaw) ?? .center
        } set: { newValue in
            projectorTextAlignmentRaw = newValue.rawValue
        }
    }

    private var projectorDirectionSelection: Binding<ProjectorReadingDirectionMode> {
        Binding {
            ProjectorReadingDirectionMode(rawValue: projectorReadingDirectionRaw) ?? .auto
        } set: { newValue in
            projectorReadingDirectionRaw = newValue.rawValue
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularControls
            compactControls
        }
        .onAppear { refreshScreenList() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshScreenList()
        }
    }

    private func refreshScreenList() {
        let activeScreens = NSScreen.screens
            .filter { $0.frame.width > 0 && $0.frame.height > 0 }
            .map { screen in
                (
                    name: screen.localizedName,
                    displayID: screen.displayID,
                    width: Int(screen.frame.width.rounded()),
                    height: Int(screen.frame.height.rounded())
                )
            }

        let countsByName = Dictionary(grouping: activeScreens, by: \.name)
            .mapValues(\.count)

        availableScreens = activeScreens.map { screen in
            let hasDuplicateName = (countsByName[screen.name] ?? 0) > 1
            let label: String

            if hasDuplicateName {
                label = "\(screen.name) • \(screen.width)x\(screen.height) • #\(screen.displayID)"
            } else {
                label = "\(screen.name) • \(screen.width)x\(screen.height)"
            }

            return ScreenOption(
                label: label,
                displayID: screen.displayID
            )
        }

        if projectorScreenDisplayID != 0,
           !availableScreens.contains(where: { $0.displayID == projectorScreenDisplayID }) {
            projectorScreenDisplayID = 0
        }
    }

    private var regularControls: some View {
        HStack(alignment: .center, spacing: 12) {
            transparentBackgroundToggle
            translationInfoToggle
            projectorScreenPicker
            projectorAlignmentSegmentedControl
            projectorDirectionSegmentedControl
            projectorDualLayoutSegmentedControl
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var compactControls: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Menu {
                Toggle("Transparent BG", isOn: $transparentBackground)
                Toggle("Show Translations", isOn: $projectorShowTranslationInfo)
                Divider()
                Picker("Projector Screen", selection: $projectorScreenDisplayID) {
                    Text("Auto").tag(0)
                    ForEach(availableScreens) { screen in
                        Text(screen.label).tag(screen.displayID)
                    }
                }
                Divider()
                Picker("Projector Alignment", selection: projectorAlignmentSelection) {
                    Label("Align Left", systemImage: "text.alignleft")
                        .tag(ProjectorTextAlignmentMode.left)
                    Label("Align Center", systemImage: "text.aligncenter")
                        .tag(ProjectorTextAlignmentMode.center)
                    Label("Align Right", systemImage: "text.alignright")
                        .tag(ProjectorTextAlignmentMode.right)
                }
                Divider()
                Picker("Projector Direction", selection: projectorDirectionSelection) {
                    Label("Direction Auto", systemImage: "arrow.left.and.right")
                        .tag(ProjectorReadingDirectionMode.auto)
                    Label("Direction LTR", systemImage: "arrow.right")
                        .tag(ProjectorReadingDirectionMode.leftToRight)
                    Label("Direction RTL", systemImage: "arrow.left")
                        .tag(ProjectorReadingDirectionMode.rightToLeft)
                }
                Divider()
                Picker("Dual layout", selection: $projectorDualLayoutVertical) {
                    Label("Side by side", systemImage: "rectangle.split.2x1")
                        .tag(false)
                    Label("Stacked", systemImage: "rectangle.split.1x2")
                        .tag(true)
                }
            } label: {
                Image(systemName: "display")
                    .accessibilityLabel("Projection options")
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var transparentBackgroundToggle: some View {
        Toggle("Transparent BG", isOn: $transparentBackground)
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Use transparent background for projector window")
            .fixedSize()
    }

    private var translationInfoToggle: some View {
        Toggle("Show Translations", isOn: $projectorShowTranslationInfo)
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Show translation names on the projector reference line")
            .fixedSize()
    }

    private var projectorAlignmentSegmentedControl: some View {
        Picker("Projector alignment", selection: projectorAlignmentSelection) {
            Label("Align Left", systemImage: "text.alignleft")
                .labelStyle(.iconOnly)
                .tag(ProjectorTextAlignmentMode.left)
            Label("Align Center", systemImage: "text.aligncenter")
                .labelStyle(.iconOnly)
                .tag(ProjectorTextAlignmentMode.center)
            Label("Align Right", systemImage: "text.alignright")
                .labelStyle(.iconOnly)
                .tag(ProjectorTextAlignmentMode.right)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
        .help("Projector alignment")
        .accessibilityLabel("Projector alignment")
    }

    private var projectorDirectionSegmentedControl: some View {
        Picker("Projector direction", selection: projectorDirectionSelection) {
            Label("Direction Auto", systemImage: "arrow.left.and.right")
                .labelStyle(.iconOnly)
                .tag(ProjectorReadingDirectionMode.auto)
            Label("Direction LTR", systemImage: "arrow.right")
                .labelStyle(.iconOnly)
                .tag(ProjectorReadingDirectionMode.leftToRight)
            Label("Direction RTL", systemImage: "arrow.left")
                .labelStyle(.iconOnly)
                .tag(ProjectorReadingDirectionMode.rightToLeft)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 120)
        .help("Projector reading direction")
        .accessibilityLabel("Projector reading direction")
    }

    private var projectorDualLayoutSegmentedControl: some View {
        Picker("Dual translation layout", selection: $projectorDualLayoutVertical) {
            Label("Side by side", systemImage: "rectangle.split.2x1")
                .labelStyle(.iconOnly)
                .tag(false)
            Label("Stacked", systemImage: "rectangle.split.1x2")
                .labelStyle(.iconOnly)
                .tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 88)
        .help("Dual translation layout")
        .accessibilityLabel("Dual translation layout")
    }

    private var projectorScreenPicker: some View {
        Picker("Screen", selection: $projectorScreenDisplayID) {
            Text("Auto").tag(0)
            ForEach(availableScreens) { screen in
                Text(screen.label).tag(screen.displayID)
            }
        }
        .controlSize(.small)
        .fixedSize()
        .help("Choose which screen to project on")
        .accessibilityLabel("Projector screen")
    }
}

private struct ScreenOption: Identifiable {
    let label: String
    let displayID: Int

    var id: Int { displayID }
}
