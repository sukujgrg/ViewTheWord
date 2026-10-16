import AppKit

@MainActor
final class OutputProfileEditor: NSViewController, NSTextFieldDelegate {
    let store: OutputConfigurationStore
    private(set) var profileID: UUID
    let nameField = NSTextField()
    let validationLabel = NSTextField(wrappingLabelWithString: "")
    let standbyClockButton = NSButton(checkboxWithTitle: "Show clock when empty or blanked", target: nil, action: nil)
    private(set) var rows: [ProfileSettingRow] = []
    var onStandbyChanged: (UUID, Bool) -> Void = { _, _ in }
    private var isActive = true
    private var renderedProfile: NativeOutputProfile?
    private struct NameEdit { let id: UUID; var text: String }
    private var nameEdit: NameEdit?
    private var bindings: [(NativeOutputProfile) -> Void] = []
    private var choices: [NSPopUpButton: (inout NativeOutputProfile, Int) -> Void] = [:]
    private var toggles: [NSButton: (inout NativeOutputProfile, Bool) -> Void] = [:]
    private var colors: [NSColorWell: WritableKeyPath<NativeOutputProfile, OutputColor>] = [:]
    init(store: OutputConfigurationStore, profileID: UUID) {
        self.store = store; self.profileID = profileID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        guard let profile = store.profile(profileID) else { return }
        nameField.stringValue = profile.name; nameField.delegate = self; nameField.setAccessibilityLabel("Profile name")
        let explanation = NSTextField(wrappingLabelWithString: "Changes apply to every native output using this profile. Font sizes are maximums; scripture shrinks to fit. Bible translations come from the committed passage.")
        explanation.font = .systemFont(ofSize: 12); explanation.textColor = .secondaryLabelColor
        validationLabel.font = .systemFont(ofSize: 12); validationLabel.textColor = .systemOrange
        validationLabel.isHidden = true
        let stack = NSStackView(views: [nativeLabel("Appearance profile", weight: .semibold), outputRow("Name", nameField), validationLabel, explanation])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.addArrangedSubview(nativeLabel("Visible components", weight: .semibold))
        for (title, key) in [("Primary verse", \NativeOutputProfile.showPrimary), ("Secondary verse", \.showSecondary), ("Reference", \.showReference), ("Translation names", \.showTranslationNames)] {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggleChanged(_:)))
            button.state = profile[keyPath: key] ? .on : .off
            bindings.append { button.state = $0[keyPath: key] ? .on : .off }
            toggles[button] = { $0[keyPath: key] = $1 }; stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(separator())
        for (title, key) in [("Verse text", \NativeOutputProfile.verse), ("Reference", \.reference), ("Translation names", \.translationNames)] {
            let type = profile[keyPath: key]
            let row = ProfileSettingRow(title: title, range: 1...200, value: type.size) { [weak self] value in self?.edit { $0[keyPath: key].size = value } }
            rows.append(row); stack.addArrangedSubview(row)
            bindings.append { row.render($0[keyPath: key].size) }
            let family = choice(OutputFontFamily.allCases.map { $0.rawValue.capitalized }, selected: OutputFontFamily.allCases.firstIndex(of: type.family)!) { $0[keyPath: key].family = OutputFontFamily.allCases[$1] }
            let weight = choice(OutputFontWeight.allCases.map { $0.rawValue.capitalized }, selected: OutputFontWeight.allCases.firstIndex(of: type.weight)!) { $0[keyPath: key].weight = OutputFontWeight.allCases[$1] }
            bindings.append { value in
                family.selectItem(at: OutputFontFamily.allCases.firstIndex(of: value[keyPath: key].family)!)
                weight.selectItem(at: OutputFontWeight.allCases.firstIndex(of: value[keyPath: key].weight)!)
            }
            family.setAccessibilityLabel(title + " font family"); weight.setAccessibilityLabel(title + " font weight")
            stack.addArrangedSubview(outputRow("Font", horizontalStack([family, weight])))
        }
        let padding = ProfileSettingRow(title: "Padding", range: 0...200, value: profile.padding) { [weak self] value in self?.edit { $0.padding = value } }
        rows.append(padding); stack.addArrangedSubview(padding)
        bindings.append { padding.render($0.padding) }
        let alignment = choice(["Left", "Center", "Right"], selected: ProjectorTextAlignmentMode.allCases.firstIndex(of: profile.alignment)!) { $0.alignment = ProjectorTextAlignmentMode.allCases[$1] }
        let direction = choice(["Automatic", "Left to right", "Right to left"], selected: ProjectorReadingDirectionMode.allCases.firstIndex(of: profile.readingDirection)!) { $0.readingDirection = ProjectorReadingDirectionMode.allCases[$1] }
        let translations = choice(["Side by side", "Stacked vertically"], selected: profile.translationLayout == .horizontal ? 0 : 1) { $0.translationLayout = $1 == 0 ? .horizontal : .vertical }
        let placement = choice(["Full frame", "Lower third"], selected: profile.placement == .fullFrame ? 0 : 1) { $0.placement = $1 == 0 ? .fullFrame : .lowerThird }
        for (title, control) in [("Alignment", alignment), ("Reading direction", direction), ("Translations", translations), ("Placement", placement)] {
            stack.addArrangedSubview(outputRow(title, control))
        }
        bindings.append {
            alignment.selectItem(at: ProjectorTextAlignmentMode.allCases.firstIndex(of: $0.alignment)!)
            direction.selectItem(at: ProjectorReadingDirectionMode.allCases.firstIndex(of: $0.readingDirection)!)
            translations.selectItem(at: $0.translationLayout == .horizontal ? 0 : 1)
            placement.selectItem(at: $0.placement == .fullFrame ? 0 : 1)
        }
        standbyClockButton.state = profile.standby == .clock ? .on : .off
        standbyClockButton.target = self; standbyClockButton.action = #selector(toggleChanged(_:))
        toggles[standbyClockButton] = { $0.standby = $1 ? .clock : .hidden }
        let standby = standbyClockButton
        bindings.append { standby.state = $0.standby == .clock ? .on : .off }
        stack.addArrangedSubview(standbyClockButton)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(nativeLabel("Colours and background", weight: .semibold))
        for (title, key) in [("Primary verse", \NativeOutputProfile.primaryColor), ("Secondary verse", \.secondaryColor), ("Reference", \.referenceColor), ("Translation names", \.translationNamesColor), ("Background", \.background)] {
            let well = NSColorWell(); well.color = profile[keyPath: key].nsColor; well.target = self; well.action = #selector(colorChanged(_:))
            well.setAccessibilityLabel(title + " colour"); colors[well] = key
            bindings.append { value in
                let color = value[keyPath: key].nsColor
                if well.color != color { well.color = color }
            }
            stack.addArrangedSubview(outputRow(title, well))
        }
        let transparent = NSButton(checkboxWithTitle: "Transparent background", target: self, action: #selector(toggleChanged(_:)))
        transparent.state = profile.transparent ? .on : .off; toggles[transparent] = { $0.transparent = $1 }
        bindings.append { transparent.state = $0.transparent ? .on : .off }
        stack.addArrangedSubview(transparent)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = OutputEditorDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        pin(scroll, to: view); stack.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16)
        ])
        for item in stack.arrangedSubviews { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        renderedProfile = profile
    }
    /// One form, rebound only after the previous item's field editor finishes.
    func represent(_ id: UUID) {
        finishNameEditing()
        guard store.profile(id) != nil else { isActive = false; return }
        if profileID != id { validationLabel.stringValue = ""; validationLabel.isHidden = true }
        profileID = id; isActive = true
        if !isViewLoaded { _ = view }
        refresh()
    }
    func deactivate() {
        finishNameEditing(); isActive = false; renderedProfile = nil
        validationLabel.stringValue = ""; validationLabel.isHidden = true
    }
    func refresh() {
        guard isActive, isViewLoaded, let profile = store.profile(profileID), profile != renderedProfile else { return }
        if nameEdit == nil, nameField.stringValue != profile.name { nameField.stringValue = profile.name }
        for binding in bindings { binding(profile) }
        renderedProfile = profile
    }
    private func choice(_ titles: [String], selected: Int, apply: @escaping (inout NativeOutputProfile, Int) -> Void) -> NSPopUpButton {
        let picker = NSPopUpButton(); picker.addItems(withTitles: titles); picker.selectItem(at: selected)
        picker.target = self; picker.action = #selector(choiceChanged(_:)); choices[picker] = apply
        return picker
    }
    @discardableResult private func edit(_ body: (inout NativeOutputProfile) -> Void) -> UUID? {
        guard isActive, var profile = store.profile(profileID) else { return nil }
        body(&profile); validationLabel.stringValue = store.updateProfile(profile) ?? ""
        validationLabel.isHidden = validationLabel.stringValue.isEmpty
        return profile.id
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard isActive, notification.object as? NSTextField === nameField else { return }
        nameEdit = NameEdit(id: profileID, text: nameField.stringValue)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === nameField else { return }
        nameEdit?.text = nameField.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === nameField else { return }
        finishNameEditing()
    }
    func finishNameEditing() {
        guard let draft = nameEdit else { return }
        nameEdit = nil
        guard var profile = store.profile(draft.id) else { return }
        profile.name = (draft.id == profileID ? nameField.stringValue : draft.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let issue = profile == store.profile(draft.id) ? nil : store.updateProfile(profile)
        if draft.id == profileID {
            validationLabel.stringValue = issue ?? ""; validationLabel.isHidden = issue == nil
            nameField.stringValue = store.profile(draft.id)?.name ?? ""
        }
    }
    @objc private func choiceChanged(_ sender: NSPopUpButton) { if let apply = choices[sender] { edit { apply(&$0, sender.indexOfSelectedItem) } } }
    @objc private func toggleChanged(_ sender: NSButton) {
        guard let apply = toggles[sender] else { return }
        let id = edit { apply(&$0, sender.state == .on) }
        if sender === standbyClockButton, let id { onStandbyChanged(id, sender.state == .on) }
    }
    @objc private func colorChanged(_ sender: NSColorWell) { if let key = colors[sender] { edit { $0[keyPath: key] = OutputColor(sender.color) } } }
}

/// Native mouse tracking drafts the readout; mouse-up, keyboard and accessibility commit.
@MainActor
final class ProfileSettingsSlider: NSSlider {
    private(set) var isTrackingMouse = false
    var onTrackingEnded: () -> Void = {}
    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true; super.mouseDown(with: event); isTrackingMouse = false; onTrackingEnded()
    }
}
@MainActor
final class ProfileSettingRow: NSView {
    let slider = ProfileSettingsSlider()
    let valueLabel = nativeLabel()
    private let onCommit: (Double) -> Void
    init(title: String, range: ClosedRange<Double>, value: Double, onCommit: @escaping (Double) -> Void) {
        self.onCommit = onCommit; super.init(frame: .zero)
        let label = nativeLabel(title); label.widthAnchor.constraint(equalToConstant: 112).isActive = true
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound; slider.doubleValue = value
        slider.altIncrementValue = 1; slider.isContinuous = true; slider.target = self; slider.action = #selector(sliderChanged(_:))
        slider.setAccessibilityLabel(title + " size"); slider.setAccessibilityHelp("Adjust in points")
        slider.onTrackingEnded = { [weak self] in self?.commit() }
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right; valueLabel.widthAnchor.constraint(equalToConstant: 58).isActive = true
        pin(horizontalStack([label, slider, valueLabel], spacing: 14), to: self); heightAnchor.constraint(equalToConstant: 30).isActive = true
        updateReadout()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func render(_ value: Double) {
        guard !slider.isTrackingMouse, slider.doubleValue != value else { return }
        slider.doubleValue = value; updateReadout()
    }
    @objc private func sliderChanged(_ sender: NSSlider) { updateReadout(); if !slider.isTrackingMouse { commit() } }
    private func updateReadout() { valueLabel.stringValue = "\(Int(slider.doubleValue.rounded())) pts" }
    private func commit() { slider.doubleValue = slider.doubleValue.rounded(); updateReadout(); onCommit(slider.doubleValue) }
}
