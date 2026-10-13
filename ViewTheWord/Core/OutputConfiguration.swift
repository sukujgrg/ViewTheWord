import AppKit
import Combine

struct OutputColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1
    static let white = Self(red: 1, green: 1, blue: 1)
    static let black = Self(red: 0, green: 0, blue: 0)
    static let reference = Self(red: 0.1, green: 0.48, blue: 1)
    static let names = Self(red: 0.18, green: 0.7, blue: 0.75)
    static let chromaGreen = Self(red: 0, green: 1, blue: 0)
    var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
}

enum OutputFontFamily: String, Codable, CaseIterable, Sendable { case system, serif, rounded, monospaced }
enum OutputFontWeight: String, Codable, CaseIterable, Sendable { case regular, medium, bold, heavy }
enum OutputTranslationLayout: String, Codable, CaseIterable, Sendable { case horizontal, vertical }
enum OutputPlacement: String, Codable, CaseIterable, Sendable { case fullFrame, lowerThird }
enum OutputStandby: String, Codable, CaseIterable, Sendable { case hidden, clock }

struct OutputTypography: Codable, Equatable, Sendable {
    var size: Double
    var family: OutputFontFamily = .system
    var weight: OutputFontWeight = .heavy
    var isValid: Bool { size.isFinite && (1...200).contains(size) }
    var nsWeight: NSFont.Weight {
        switch weight { case .regular: .regular; case .medium: .medium; case .bold: .bold; case .heavy: .heavy }
    }
    func font(size: CGFloat? = nil) -> NSFont {
        let size = size ?? self.size
        if family == .monospaced { return .monospacedSystemFont(ofSize: size, weight: nsWeight) }
        let base = NSFont.systemFont(ofSize: size, weight: nsWeight)
        let design: NSFontDescriptor.SystemDesign = family == .serif ? .serif : family == .rounded ? .rounded : .default
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}

/// Appearance only. Bible selection and fetching belong to the passage workflow.
struct NativeOutputProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var verse = OutputTypography(size: AppDefaults.verseFontSize)
    var reference = OutputTypography(size: AppDefaults.referenceFontSize, weight: .bold)
    var translationNames = OutputTypography(size: AppDefaults.referenceFontSize, weight: .bold)
    var primaryColor = OutputColor.white
    var secondaryColor = OutputColor.white
    var referenceColor = OutputColor.reference
    var translationNamesColor = OutputColor.names
    var background = OutputColor.black
    var transparent = false
    var padding = AppDefaults.projectorPadding
    var alignment = ProjectorTextAlignmentMode.center
    var readingDirection = ProjectorReadingDirectionMode.auto
    var translationLayout = OutputTranslationLayout.horizontal
    var placement = OutputPlacement.fullFrame
    var showPrimary = true
    var showSecondary = true
    var showReference = true
    var showTranslationNames = true
    // Standby clocks are available to every native profile. Confidence opts in by default.
    var standby = OutputStandby.hidden

    static let audienceID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    static let confidenceID = UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!
    static let lowerThirdID = UUID(uuidString: "A0000000-0000-0000-0000-000000000003")!
    static var audience: Self { Self(id: audienceID, name: "Audience") }
    static var confidence: Self {
        var profile = Self(id: confidenceID, name: "Confidence")
        profile.translationLayout = .vertical; profile.standby = .clock
        return profile
    }
    static var lowerThird: Self {
        var profile = Self(id: lowerThirdID, name: "Lower Third")
        profile.verse.size = 48; profile.reference.size = 28; profile.translationNames.size = 22
        profile.background = .chromaGreen; profile.placement = .lowerThird
        profile.alignment = .left; profile.showSecondary = false
        return profile
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80 &&
        verse.isValid && reference.isValid && translationNames.isValid &&
        [primaryColor, secondaryColor, referenceColor, translationNamesColor, background].allSatisfy(\.isValid) &&
        padding.isFinite && (0...200).contains(padding)
    }
    /// Used by both output and preview. Missing secondary consumes no layout space.
    func components(in data: ProjectorViewData) -> OutputScriptureComponents {
        let secondary = data.secondaryText.flatMap { text in
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == "\u{200c}" ? nil : text
        }
        return OutputScriptureComponents(primary: showPrimary ? data.primaryText : nil,
            secondary: showSecondary ? secondary : nil, reference: showReference ? data.title : nil,
            primaryName: showTranslationNames && showPrimary ? data.primaryTranslationName : nil,
            secondaryName: showTranslationNames && showSecondary && secondary != nil ? data.secondaryTranslationName : nil)
    }
}

struct OutputScriptureComponents: Equatable {
    let primary: String?
    let secondary: String?
    let reference: String?
    let primaryName: String?
    let secondaryName: String?
}

struct NativeOutputAssignment: Codable, Equatable, Sendable {
    var monitor: ProjectionMonitorTarget?
    var profileID: UUID
}
struct AltViewOutputAssignment: Codable, Equatable, Sendable {
    var receiver: AltViewDestination?
    var template: AltViewContentTemplate? = .scripture
    // Receiver identity learned through authenticated welcome, also for manual addresses.
    var receiverID: UUID?
}
enum OutputAssignment: Codable, Equatable, Sendable {
    case native(NativeOutputAssignment)
    case altView(AltViewOutputAssignment)
}
struct OutputDestination: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var enabled: Bool
    var assignment: OutputAssignment
    var native: NativeOutputAssignment? { if case .native(let value) = assignment { value } else { nil } }
    var altView: AltViewOutputAssignment? { if case .altView(let value) = assignment { value } else { nil } }
}
struct OutputConfiguration: Codable, Equatable {
    var version = 1
    var profiles: [NativeOutputProfile]
    var destinations: [OutputDestination]
    var isValid: Bool {
        version == 1 && !profiles.isEmpty && profiles.allSatisfy(\.isValid) &&
        Set(profiles.map(\.id)).count == profiles.count && Set(destinations.map(\.id)).count == destinations.count &&
        destinations.allSatisfy { destination in
            guard !destination.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, destination.name.count <= 80 else { return false }
            switch destination.assignment {
            case .native(let value): return profiles.contains { $0.id == value.profileID }
            case .altView(let value): return (value.receiver?.isValid ?? true) && (value.template?.isValid ?? true)
            }
        }
    }
}

/// The only saved output configuration. Old keys are migration inputs, never live bindings.
@MainActor
final class OutputConfigurationStore: ObservableObject {
    @Published private(set) var configuration: OutputConfiguration
    @Published private(set) var recoveryNotice: String?
    private let defaults: UserDefaults
    private let displays: ProjectionDisplayManager
    private var unreadableValue: Any?
    // Live connection/discovery inventory supplies availability; isolated stores can inject it.
    var receiverIsAvailable: (OutputDestination) -> Bool = { _ in true }
    var canEdit: Bool { recoveryNotice == nil }
    var profiles: [NativeOutputProfile] { configuration.profiles }
    var destinations: [OutputDestination] { configuration.destinations }

    init(defaults: UserDefaults, displays: ProjectionDisplayManager) {
        self.defaults = defaults; self.displays = displays
        if defaults.object(forKey: AppDefaultsKey.outputConfiguration) != nil {
            let data = defaults.data(forKey: AppDefaultsKey.outputConfiguration) ?? Data()
            if let saved = try? JSONDecoder().decode(OutputConfiguration.self, from: data), saved.isValid {
                configuration = saved
            } else {
                unreadableValue = defaults.object(forKey: AppDefaultsKey.outputConfiguration)
                recoveryNotice = "Saved outputs are unreadable or from a newer version. They are preserved. Restore defaults to edit outputs; a recovery copy will be retained."
                configuration = Self.initial(audience: .audience, monitor: nil, receiver: nil)
                configuration.destinations[0].enabled = false
            }
        } else {
            var audience = NativeOutputProfile.audience
            // The former projector forced dark appearance even with a light operator workspace.
            if let legacyAppearance = NSAppearance(named: .darkAqua) {
                legacyAppearance.performAsCurrentDrawingAppearance {
                    audience.referenceColor = OutputColor(NSColor.controlAccentColor.withAlphaComponent(0.95))
                    audience.translationNamesColor = OutputColor(NSColor.systemTeal.withAlphaComponent(0.92))
                }
            }
            func number(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
                let value = (defaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
                return value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
            }
            audience.verse.size = number(AppDefaultsKey.fontSizeVerse, fallback: audience.verse.size, range: 1...200)
            audience.reference.size = number(AppDefaultsKey.fontSizeVerseRef, fallback: audience.reference.size, range: 1...200)
            audience.translationNames.size = audience.reference.size
            audience.padding = number(AppDefaultsKey.projectorPadding, fallback: audience.padding, range: 0...200)
            audience.alignment = defaults.string(forKey: AppDefaultsKey.projectorTextAlignment).flatMap(ProjectorTextAlignmentMode.init) ?? .center
            audience.readingDirection = defaults.string(forKey: AppDefaultsKey.projectorReadingDirection).flatMap(ProjectorReadingDirectionMode.init) ?? .auto
            audience.translationLayout = defaults.bool(forKey: AppDefaultsKey.projectorDualLayoutVertical) ? .vertical : .horizontal
            audience.transparent = defaults.bool(forKey: AppDefaultsKey.transparentBackground)
            audience.showTranslationNames = defaults.object(forKey: AppDefaultsKey.projectorShowTranslationInfo) == nil || defaults.bool(forKey: AppDefaultsKey.projectorShowTranslationInfo)
            let receiver = defaults.data(forKey: AppDefaultsKey.altViewDestination).flatMap { try? JSONDecoder().decode(AltViewDestination.self, from: $0) }.flatMap { $0.isValid ? $0 : nil }
            configuration = Self.initial(audience: audience, monitor: displays.legacyAssignment, receiver: receiver)
            if let raw = defaults.string(forKey: AppDefaultsKey.altViewTemplate), let index = configuration.destinations.firstIndex(where: { $0.altView != nil }) {
                var assignment = configuration.destinations[index].altView!
                let template = AltViewContentTemplate(rawValue: raw)
                assignment.template = raw.isEmpty ? nil : template.isValid ? template : .scripture
                configuration.destinations[index].assignment = .altView(assignment)
            }
            save()
        }
    }
    private static func initial(audience: NativeOutputProfile, monitor: ProjectionMonitorTarget?, receiver: AltViewDestination?) -> OutputConfiguration {
        var destinations = [OutputDestination(name: "Audience", enabled: true, assignment: .native(.init(monitor: monitor, profileID: audience.id)))]
        if let receiver {
            destinations.append(OutputDestination(name: "AltView", enabled: true, assignment: .altView(.init(receiver: receiver, receiverID: receiver.receiverIdentity))))
        }
        return OutputConfiguration(profiles: [audience, .confidence, .lowerThird], destinations: destinations)
    }
    func profile(_ id: UUID) -> NativeOutputProfile? { profiles.first { $0.id == id } }
    func destination(_ id: UUID) -> OutputDestination? { destinations.first { $0.id == id } }
    /// Only connected, usable native assignments reserve a physical monitor.
    func conflict(for destination: OutputDestination, in candidates: [OutputDestination]? = nil) -> String? {
        guard destination.enabled else { return nil }
        let others = (candidates ?? destinations).filter { $0.id != destination.id && $0.enabled }
        if let target = destination.native?.monitor, displays.resolve(target) != nil,
           let other = others.first(where: { $0.native?.monitor?.identity == target.identity }) {
            return "\(other.name) already uses this monitor. Disable it or choose another monitor."
        }
        if let assignment = destination.altView, let receiver = assignment.receiver {
            let identity = assignment.receiverID ?? receiver.receiverIdentity
            if let other = others.first(where: {
                guard receiverIsAvailable($0), let value = $0.altView, let saved = value.receiver else { return false }
                return receiver.account == saved.account || (identity != nil && identity == (value.receiverID ?? saved.receiverIdentity))
            }) { return "\(other.name) already uses this AltView receiver. Disable it or choose another receiver." }
        }
        return nil
    }
    @discardableResult func update(_ destination: OutputDestination) -> String? {
        guard canEdit else { return recoveryNotice }
        if let current = self.destination(destination.id), displays.isOutputLocked(destination.id),
           current.native?.monitor?.identity != destination.native?.monitor?.identity {
            return "Close this output before changing its monitor."
        }
        if let previous = self.destination(destination.id) {
            let changesReservation = (!previous.enabled && destination.enabled) ||
                previous.native?.monitor?.identity != destination.native?.monitor?.identity ||
                previous.altView?.receiver?.account != destination.altView?.receiver?.account ||
                previous.altView?.receiverID != destination.altView?.receiverID ||
                previous.altView?.receiver?.receiverIdentity != destination.altView?.receiver?.receiverIdentity
            if changesReservation, let conflict = conflict(for: destination) { return conflict }
        }
        var next = configuration
        guard let index = next.destinations.firstIndex(where: { $0.id == destination.id }) else { return "Output no longer exists." }
        next.destinations[index] = destination
        guard next.isValid else { return "Use a name up to 80 characters and a valid assignment." }
        configuration = next; save(); return nil
    }
    @discardableResult func addNative() -> UUID {
        let output = OutputDestination(name: "Native Output", enabled: false, assignment: .native(.init(monitor: nil, profileID: profiles.first(where: { $0.id == NativeOutputProfile.audienceID })?.id ?? profiles[0].id)))
        if canEdit { configuration.destinations.append(output); save() }
        return output.id
    }
    @discardableResult func addAltView() -> UUID {
        let output = OutputDestination(name: "AltView", enabled: false, assignment: .altView(.init(receiver: nil)))
        if canEdit { configuration.destinations.append(output); save() }
        return output.id
    }
    func remove(_ id: UUID) { guard canEdit else { return }; configuration.destinations.removeAll { $0.id == id }; save() }
    @discardableResult func updateProfile(_ profile: NativeOutputProfile) -> String? {
        guard canEdit else { return recoveryNotice }
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, profile.name.count <= 80 else {
            return "Use a profile name with 1 to 80 characters."
        }
        guard profile.isValid else { return "Use valid typography, colours and padding for this profile." }
        guard let index = configuration.profiles.firstIndex(where: { $0.id == profile.id }) else { return "Profile no longer exists." }
        configuration.profiles[index] = profile; save(); return nil
    }
    @discardableResult func duplicateProfile(_ id: UUID) -> UUID? {
        guard canEdit, var profile = profile(id) else { return nil }
        profile.id = UUID(); profile.name = String(profile.name.prefix(70)) + " Copy"
        configuration.profiles.append(profile); save(); return profile.id
    }
    func restoreDefaults() {
        guard let unreadableValue else { return }
        defaults.set(unreadableValue, forKey: AppDefaultsKey.outputRecoveryPrefix + UUID().uuidString)
        self.unreadableValue = nil; recoveryNotice = nil
        configuration = Self.initial(audience: .audience, monitor: nil, receiver: nil); save()
    }
    private func save() {
        guard canEdit, let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: AppDefaultsKey.outputConfiguration)
    }
}

/// Former monitor preference, read once during versioned output migration.
@MainActor
enum LegacyOutputSettings {
    static func monitor(defaults: UserDefaults?, displays: [ProjectionMonitor]) -> ProjectionMonitorTarget? {
        guard let defaults else { return nil }
        if defaults.object(forKey: AppDefaultsKey.projectionMonitorAssignment) != nil {
            do { return try JSONDecoder().decode(ProjectionMonitorTarget?.self, from: defaults.data(forKey: AppDefaultsKey.projectionMonitorAssignment) ?? Data()) }
            catch { return ProjectionMonitorTarget(identity: "unreadable", name: "Saved monitor (choose again)") }
        }
        guard let old = defaults.object(forKey: AppDefaultsKey.projectorScreenDisplayID) else { return nil }
        guard let number = old as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let id = UInt32(exactly: number.doubleValue) else {
            return ProjectionMonitorTarget(identity: "legacy:invalid", name: "Saved monitor (choose again)")
        }
        guard id != 0 else { return nil }
        let matches = displays.filter { $0.id == id }
        if matches.count == 1, let match = matches.first, let identity = match.identity, UUID(uuidString: identity) != nil,
           displays.filter({ $0.identity == identity }).count == 1 { return match.target }
        return ProjectionMonitorTarget(identity: "legacy:\(id)", name: "Saved monitor (choose again)")
    }
}
