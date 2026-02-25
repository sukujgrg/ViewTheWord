import SwiftUI

struct ProjectionControlsRowView: View {
    @Binding var transparentBackground: Bool
    @Binding var projectorTextAlignmentRaw: String
    @Binding var projectorReadingDirectionRaw: String
    @Binding var projectorDualLayoutVertical: Bool

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
    }

    private var regularControls: some View {
        HStack(alignment: .center, spacing: 12) {
            transparentBackgroundToggle
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
}
