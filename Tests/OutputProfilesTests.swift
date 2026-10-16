import AppKit
import Combine
import Network
import SwiftUI
import XCTest
@testable import ViewTheWordCore

private actor OutputPairings: AltViewPairingStoring {
    var values: [String: AltViewPairing] = [:]
    func read(account: String) -> AltViewPairing? { values[account] }
    func save(_ pairing: AltViewPairing, account: String) { values[account] = pairing }
}
private final class OutputSender: AltViewSending, @unchecked Sendable {
    var callback: (@Sendable (AltViewSenderStatus) -> Void)?
    var connectionID: UUID?
    var receiverID = UUID()
    var submissions: [AltViewSubmission] = []
    var connectCount = 0
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID) {
        self.connectionID = connectionID; receiverID = expectedReceiverID ?? receiverID; connectCount += 1
    }
    func welcome() { callback?(.init(connectionID: connectionID, connected: true, receiverID: receiverID)) }
    func disconnect() { connectionID = nil }
    func submit(_ submission: AltViewSubmission) { submissions.append(submission) }
}
private final class OutputDiscovery: AltViewDiscovering {
    var starts = 0; var stops = 0
    func start() { starts += 1 }; func stop() { stops += 1 }
}
@MainActor private final class OutputInventory {
    var monitors: [ProjectionMonitor]
    init(_ monitors: [ProjectionMonitor]) { self.monitors = monitors }
}
@MainActor private final class OutputWindow: NSWindow {
    var frontCount = 0
    override func orderFrontRegardless() { frontCount += 1 }
}

@MainActor
final class OutputProfilesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "OutputProfiles.\(UUID())"
        let isolated = UserDefaults(suiteName: suite)!
        addTeardownBlock { isolated.removePersistentDomain(forName: suite) }; return isolated
    }
    private func monitor(_ id: Int) -> ProjectionMonitor {
        ProjectionMonitor(id: UInt32(id), identity: "\(String(repeating: String(id), count: 8))-1111-1111-1111-111111111111", name: "TV \(id)", frame: CGRect(x: -10000 - id * 1000, y: -10000, width: 800, height: 450))
    }
    private func projection(_ text: String = "Committed primary", secondary: String? = "Committed secondary") -> PreparedProjection {
        let reference = VerseReference(book: "John", chapter: 3, verse: 16)!
        return PreparedProjection(pair: .init(reference: reference, primary: .init(reference: reference, verse: text), secondary: secondary.map { .init(reference: reference, verse: $0) }), sources: .init(primary: URL(fileURLWithPath: "/tmp/ENG_NIV.bible"), secondary: URL(fileURLWithPath: "/tmp/ENG_NLT.bible"), revision: 1), owner: .verseRowSelection(reference))!
    }
    private func settle() async { for _ in 0..<12 { await Task.yield() } }
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        XCTFail("Output state did not settle")
    }
    private func assign(_ store: OutputConfigurationStore, _ id: UUID, to monitor: ProjectionMonitor?, profile: UUID, enabled: Bool = true) {
        var destination = store.destination(id)!; destination.enabled = enabled
        destination.assignment = .native(.init(monitor: monitor?.target, profileID: profile)); XCTAssertNil(store.update(destination))
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func testSettingsNavigationReusesFormsWithoutChangingCommittedOutputOrConnections() async throws {
        _ = NSApplication.shared
        let sender = OutputSender()
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [self.monitor(1)] }),
            altViewServiceFactory: { saved, discovery in
                AltViewProjectionService(destination: saved.receiver, store: OutputPairings(), discovery: discovery) { sender.callback = $0; return sender }
            })
        defer { live.shutdown() }
        live.nativeWindowFactory = { _, _, _ in nil }
        let audience = live.outputs.destinations[0].id, native = live.outputs.addNative(), remote = live.outputs.addAltView()
        assign(live.outputs, audience, to: monitor(1), profile: NativeOutputProfile.audienceID)
        XCTAssertNil(live.connectAltView(remote, to: .init(name: "Receiver", host: "receiver.local", port: 54321), code: "ABCD2345"))
        try await eventually { sender.connectionID != nil }; sender.welcome(); await settle()
        live.publishRow(projection(), from: UUID())
        let configuration = live.outputs.configuration, data = live.projector.projectorViewData, revision = live.projector.revision
        let source = live.source, submissions = sender.submissions.count, connects = sender.connectCount
        let manager = ManageOutputsController(live: live); manager.discoveryEnabled = false; _ = manager.view
        let nativeForm = manager.monitorPicker.superview
        manager.selectProfile(NativeOutputProfile.audienceID)
        let form = try XCTUnwrap(manager.profileEditor), slider = form.rows[0].slider
        for _ in 0..<3 {
            for profile in live.outputs.profiles {
                manager.selectProfile(profile.id)
                XCTAssertTrue(manager.profileEditor === form && form.rows[0].slider === slider)
                XCTAssertEqual(form.profileID, profile.id); XCTAssertEqual(form.rows[0].slider.doubleValue, profile.verse.size)
            }
            for id in [audience, native, remote, audience] { manager.selectDestination(id) }
            XCTAssertTrue(manager.monitorPicker.superview === nativeForm)
        }
        await settle()
        let nativeOutputs = Set(live.nativeOutputs.keys)
        manager.stopDiscovery()
        manager.enabledButton.performClick(nil); manager.standbyClockButton.performClick(nil)
        let close = try XCTUnwrap(descendants(manager.view).compactMap { $0 as? NSButton }.first { $0.title == "Close This Output" })
        close.performClick(nil)
        XCTAssertEqual(Set(live.nativeOutputs.keys), nativeOutputs, "Late actions from hidden native controls must not stop output")
        manager.startDiscovery()
        XCTAssertEqual(manager.enabledButton.state, .on)
        XCTAssertEqual(live.outputs.configuration, configuration)
        XCTAssertEqual(live.projector.projectorViewData, data); XCTAssertEqual(live.projector.revision, revision); XCTAssertEqual(live.source, source)
        XCTAssertEqual(sender.submissions.count, submissions); XCTAssertEqual(sender.connectCount, connects)
        XCTAssertTrue(live.altViewServices[remote]!.status.connected)
    }
    func testReusedProfileFormCommitsOriginalDraftAndIgnoresLateOrHiddenCallbacks() throws {
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        defer { live.shutdown() }
        let manager = ManageOutputsController(live: live); _ = manager.view
        manager.selectProfile(NativeOutputProfile.audienceID)
        let editor = try XCTUnwrap(manager.profileEditor)
        editor.controlTextDidBeginEditing(.init(name: NSControl.textDidBeginEditingNotification, object: editor.nameField))
        editor.nameField.stringValue = "Original draft"
        editor.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: editor.nameField))
        manager.selectProfile(NativeOutputProfile.confidenceID)
        XCTAssertTrue(manager.profileEditor === editor)
        XCTAssertEqual(live.outputs.profile(NativeOutputProfile.audienceID)?.name, "Original draft")
        editor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: editor.nameField))
        XCTAssertEqual(live.outputs.profile(NativeOutputProfile.confidenceID)?.name, "Confidence")
        var callbackID: UUID?
        editor.onStandbyChanged = { id, _ in callbackID = id }
        editor.standbyClockButton.performClick(nil)
        XCTAssertEqual(callbackID, NativeOutputProfile.confidenceID)
        manager.selectDestination(live.outputs.destinations[0].id)
        let saved = live.outputs.configuration
        let slider = editor.rows[0].slider; slider.doubleValue = 99
        slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(live.outputs.configuration, saved, "Detached forms must ignore callbacks")
        editor.represent(UUID())
        editor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: editor.nameField))
        slider.sendAction(slider.action, to: slider.target)
        XCTAssertEqual(live.outputs.configuration, saved, "An unavailable binding cannot save through stale controls")
    }
    func testAltViewEditorsPauseHiddenUpdatesRetainDraftsAndDiscardChangedDestinations() async throws {
        let sender = OutputSender()
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [] }),
            altViewServiceFactory: { saved, discovery in
                AltViewProjectionService(destination: saved.receiver, store: OutputPairings(), discovery: discovery) { sender.callback = $0; return sender }
            })
        defer { live.shutdown() }
        let id = live.outputs.addAltView(), other = live.outputs.addAltView(); live.refreshPreferences()
        let manager = ManageOutputsController(live: live); manager.discoveryEnabled = false; _ = manager.view; manager.selectDestination(id)
        let editor = try XCTUnwrap(manager.remoteEditor)
        XCTAssertNil(live.connectAltView(id, to: .init(name: "Receiver", host: "receiver.local", port: 54321), code: "ABCD2345"))
        try await eventually { sender.connectionID != nil }; sender.welcome(); await settle()
        let receiverItem = editor.receiverPicker.item(at: 0), templateItem = editor.templatePicker.item(at: 0)
        func status(_ message: String) { sender.callback?(.init(connectionID: sender.connectionID, connected: true, receiverID: sender.receiverID, message: message)) }
        status("Visible update"); await settle()
        XCTAssertTrue(editor.statusLabel.stringValue.contains("Visible update"))
        manager.selectProfile(NativeOutputProfile.audienceID)
        status("Hidden update"); await settle()
        XCTAssertFalse(editor.statusLabel.stringValue.contains("Hidden update"))
        manager.selectDestination(id)
        XCTAssertTrue(manager.remoteEditor === editor); XCTAssertTrue(editor.statusLabel.stringValue.contains("Hidden update"))
        XCTAssertTrue(editor.receiverPicker.item(at: 0) === receiverItem && editor.templatePicker.item(at: 0) === templateItem)
        manager.selectDestination(other)
        let draftEditor = try XCTUnwrap(manager.remoteEditor)
        draftEditor.hostField.stringValue = "unsaved.local"; draftEditor.codeField.stringValue = "ABCD2345"
        manager.selectDestination(id); manager.selectDestination(other)
        XCTAssertTrue(manager.remoteEditor === draftEditor); XCTAssertEqual(draftEditor.hostField.stringValue, "unsaved.local")
        XCTAssertEqual(draftEditor.codeField.stringValue, "ABCD2345")
        manager.selectDestination(id); manager.stopDiscovery()
        status("Closed update"); await settle()
        XCTAssertFalse(editor.statusLabel.stringValue.contains("Closed update")); XCTAssertTrue(live.altViewServices[id]!.status.connected)
        manager.startDiscovery(); XCTAssertTrue(editor.statusLabel.stringValue.contains("Closed update"))
        manager.stopDiscovery()
        var changed = live.outputs.destination(id)!
        changed.enabled = false; changed.assignment = .native(.init(monitor: nil, profileID: NativeOutputProfile.audienceID))
        XCTAssertNil(live.outputs.update(changed))
        XCTAssertNil(manager.remoteEditor, "Deleted or changed-type editors must be discarded even while Settings is hidden")
        live.refreshPreferences(); manager.startDiscovery()
        XCTAssertNil(manager.remoteEditor)
        XCTAssertNotNil(editor.onConnect(.init(name: "Stale", host: "stale.local", port: 54321), "ABCD2345"))
        XCTAssertEqual(live.outputs.destination(id), changed)
        manager.selectDestination(other); manager.stopDiscovery()
        var saved = live.outputs.destination(other)!, assignment = saved.altView!
        assignment.receiver = .init(name: "Updated", host: "updated.local", port: 54321); saved.assignment = .altView(assignment)
        XCTAssertNil(live.outputs.update(saved))
        XCTAssertEqual(draftEditor.hostField.stringValue, "unsaved.local", "Hidden editors should defer saved-assignment UI changes")
        manager.startDiscovery()
        XCTAssertTrue(manager.remoteEditor === draftEditor); XCTAssertEqual(draftEditor.hostField.stringValue, "updated.local")
        manager.stopDiscovery(); live.outputs.remove(other)
        XCTAssertNil(manager.remoteEditor)
        XCTAssertNotNil(draftEditor.onSelectReceiver(.init(name: "Deleted", host: "deleted.local", port: 54321)))
    }
    func testAddingAltViewShowsConnectionControlsImmediatelyWithoutReselection() async throws {
        _ = NSApplication.shared
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        defer { live.shutdown() }
        let manager = ManageOutputsController(live: live); manager.discoveryEnabled = false; _ = manager.view
        let add = try XCTUnwrap(manager.addOutputButton.menu?.items.first { $0.title == "AltView Output" })
        let originalDestinations = live.outputs.destinations
        for _ in 0..<2 {
            NSApp.sendAction(add.action!, to: add.target, from: add)
            let output = try XCTUnwrap(live.outputs.destinations.last)
            let service = try XCTUnwrap(live.altViewServices[output.id], "Adding an AltView output must prepare its service before rendering its editor")
            let editor = try XCTUnwrap(manager.remoteEditor, "Connection controls must appear in the same Add action without switching selection")
            XCTAssertEqual(manager.nameField.stringValue, output.name)
            XCTAssertTrue(editor.receiverPicker.isDescendant(of: manager.view))
            XCTAssertTrue(editor.codeField.isDescendant(of: manager.view))
            XCTAssertTrue(editor.connectButton.isDescendant(of: manager.view))
            XCTAssertFalse(output.enabled); XCTAssertFalse(service.isEnabled); XCTAssertFalse(service.status.connected)
            await settle()
            XCTAssertTrue(manager.remoteEditor === editor, "Deferred preference updates must retain the complete editor")
        }
        XCTAssertEqual(Array(live.outputs.destinations.prefix(originalDestinations.count)), originalDestinations)
        XCTAssertEqual(live.altViewServices.count, 2)
        XCTAssertNil(live.projector.projection); XCTAssertNil(live.source)
    }
    func testRemovingLastDestinationAndReopeningManagerShowsEmptyState() throws {
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        defer { live.shutdown() }
        let manager = ManageOutputsController(live: live); _ = manager.view
        manager.removeOutputButton.performClick(nil)
        XCTAssertTrue(live.outputs.destinations.isEmpty)
        XCTAssertFalse(manager.nameField.isDescendant(of: manager.view), "Removed destinations must not leave their editable form behind")
        func hasEmptyHint(_ manager: ManageOutputsController) -> Bool {
            descendants(manager.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Add an output to get started." }
        }
        XCTAssertTrue(hasEmptyHint(manager))
        let reopened = ManageOutputsController(live: live); _ = reopened.view
        XCTAssertTrue(hasEmptyHint(reopened), "An already-empty saved configuration also needs a usable empty state")
    }
    func testOutputFooterMenuCommitsDraftsMarksDefaultsAndKeepsHiddenActionsInactive() throws {
        _ = NSApplication.shared
        let sender = OutputSender()
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [] }),
            altViewServiceFactory: { saved, discovery in
                AltViewProjectionService(destination: saved.receiver, store: OutputPairings(), discovery: discovery) { sender.callback = $0; return sender }
            })
        defer { live.shutdown() }
        let manager = ManageOutputsController(live: live); manager.discoveryEnabled = false; _ = manager.view
        let audience = live.outputs.destinations[0].id
        let menu = try XCTUnwrap(manager.addOutputButton.menu)
        XCTAssertEqual(menu.items.map(\.title), ["Native Output", "AltView Output"])
        XCTAssertTrue(menu.items.allSatisfy { !$0.isHidden }, "Pull-down attachment must not consume the first creation command as its title")
        XCTAssertFalse(manager.addOutputButton.usesItemFromMenu)
        XCTAssertNotNil(manager.addOutputButton.image, "The static + icon must be independent of the menu's textual items")
        XCTAssertEqual(manager.addOutputButton.accessibilityLabel(), "Add output")
        XCTAssertEqual(manager.removeOutputButton.accessibilityLabel(), "Remove output")
        XCTAssertEqual(manager.table.focusRingType, .none)
        XCTAssertEqual(manager.defaultButton.title, "Default"); XCTAssertFalse(manager.defaultButton.isEnabled)
        XCTAssertTrue(manager.addProfileButton.isHiddenOrHasHiddenAncestor)
        manager.controlTextDidBeginEditing(.init(name: NSControl.textDidBeginEditingNotification, object: manager.nameField))
        manager.nameField.stringValue = "Audience renamed"
        manager.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: manager.nameField))
        for item in menu.items {
            NSApp.sendAction(item.action!, to: item.target, from: item)
            let added = try XCTUnwrap(live.outputs.destinations.last)
            XCTAssertEqual(live.outputs.destination(audience)?.name, "Audience renamed", "Add must finish the original name draft before changing selection")
            XCTAssertEqual(added.native != nil, item.title == "Native Output")
            XCTAssertFalse(added.enabled)
            XCTAssertEqual(manager.defaultButton.title, "Make Default"); XCTAssertTrue(manager.defaultButton.isEnabled)
            manager.defaultButton.performClick(nil)
            XCTAssertEqual(live.outputs.defaultDestination?.id, added.id)
            XCTAssertFalse(live.outputs.defaultDestination!.enabled, "Choosing a disabled default must not enable it")
            XCTAssertEqual(manager.defaultButton.title, "Default"); XCTAssertFalse(manager.defaultButton.isEnabled)
            let saved = live.outputs.configuration
            manager.defaultButton.performClick(nil)
            XCTAssertEqual(live.outputs.configuration, saved, "Default is a one-way action, not an on/off toggle")
            let row = try XCTUnwrap(live.outputs.destinations.firstIndex { $0.id == added.id })
            let cell = try XCTUnwrap(manager.tableView(manager.table, viewFor: manager.table.tableColumns[0], row: row))
            XCTAssertTrue(cell.accessibilityLabel()?.hasSuffix(", Default") == true)
            let marker = descendants(cell).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Default" }
            XCTAssertEqual(marker?.isHidden, false)
        }
        let selected = live.outputs.defaultDestination!.id
        let saved = live.outputs.configuration
        manager.selectProfile(NativeOutputProfile.audienceID)
        XCTAssertTrue(manager.addOutputButton.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(manager.defaultButton.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(manager.addProfileButton.isHiddenOrHasHiddenAncestor)
        for item in menu.items { NSApp.sendAction(item.action!, to: item.target, from: item) }
        NSApp.sendAction(manager.removeOutputButton.action!, to: manager.removeOutputButton.target, from: manager.removeOutputButton)
        NSApp.sendAction(manager.defaultButton.action!, to: manager.defaultButton.target, from: manager.defaultButton)
        XCTAssertEqual(live.outputs.configuration, saved)
        manager.selectDestination(selected)
        XCTAssertFalse(manager.addOutputButton.isHiddenOrHasHiddenAncestor)
        XCTAssertNotNil(manager.addOutputButton.image, "The add icon must survive menu selection and section reattachment")
        XCTAssertTrue(menu.items.allSatisfy { !$0.isHidden })
        XCTAssertFalse(manager.removeOutputButton.isHiddenOrHasHiddenAncestor)
        manager.removeOutputButton.performClick(nil)
        XCTAssertNil(live.outputs.defaultDestination, "Removing the default must leave None, without choosing the next row")
        XCTAssertNil(live.altViewServices[selected])
        manager.stopDiscovery()
        let stopped = live.outputs.configuration
        for item in menu.items { NSApp.sendAction(item.action!, to: item.target, from: item) }
        NSApp.sendAction(manager.defaultButton.action!, to: manager.defaultButton.target, from: manager.defaultButton)
        NSApp.sendAction(manager.removeOutputButton.action!, to: manager.removeOutputButton.target, from: manager.removeOutputButton)
        XCTAssertEqual(live.outputs.configuration, stopped)
        XCTAssertEqual(sender.connectCount, 0); XCTAssertTrue(sender.submissions.isEmpty)
        XCTAssertTrue(live.nativeOutputs.isEmpty); XCTAssertNil(live.source); XCTAssertNil(live.projector.projectionOwner)
    }
    func testNameDraftRemainsBoundToItsDestinationWhenSelectionChanges() {
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        defer { live.shutdown() }
        let first = live.outputs.destinations[0].id, second = live.outputs.addNative()
        let secondName = live.outputs.destination(second)!.name
        let manager = ManageOutputsController(live: live); _ = manager.view; manager.selectDestination(first)
        let delegate = manager as NSTextFieldDelegate
        delegate.controlTextDidBeginEditing?(.init(name: NSControl.textDidBeginEditingNotification, object: manager.nameField))
        manager.nameField.stringValue = "Edited Audience"
        delegate.controlTextDidChange?(.init(name: NSControl.textDidChangeNotification, object: manager.nameField))
        manager.selectDestination(second)
        delegate.controlTextDidEndEditing?(.init(name: NSControl.textDidEndEditingNotification, object: manager.nameField))
        XCTAssertEqual(live.outputs.destination(first)?.name, "Edited Audience")
        XCTAssertEqual(live.outputs.destination(second)?.name, secondName)
        XCTAssertEqual(manager.nameField.stringValue, secondName)
    }
    func testInvalidProfileNameShowsValidationAndRetainsTheSavedAppearance() {
        let preferences = defaults(), store = OutputConfigurationStore(defaults: preferences, displays: ProjectionDisplayManager(displays: { [] }))
        let original = store.profiles[0], editor = OutputProfileEditor(store: store, profileID: original.id)
        _ = editor.view
        let data = preferences.data(forKey: AppDefaultsKey.outputConfiguration)
        for invalid in ["   ", String(repeating: "x", count: 81)] {
            editor.controlTextDidBeginEditing(.init(name: NSControl.textDidBeginEditingNotification, object: editor.nameField))
            editor.nameField.stringValue = invalid
            editor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: editor.nameField))
            XCTAssertEqual(store.profile(original.id), original); XCTAssertEqual(preferences.data(forKey: AppDefaultsKey.outputConfiguration), data)
            XCTAssertEqual(editor.nameField.stringValue, original.name)
            XCTAssertEqual(editor.validationLabel.stringValue, "Use a profile name with 1 to 80 characters.")
        }
        editor.controlTextDidBeginEditing(.init(name: NSControl.textDidBeginEditingNotification, object: editor.nameField))
        editor.nameField.stringValue = " Renamed profile "
        editor.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: editor.nameField))
        XCTAssertEqual(store.profile(original.id)?.name, "Renamed profile"); XCTAssertTrue(editor.validationLabel.stringValue.isEmpty)
    }
    func testInvalidAltViewOutputNameShowsValidationAndDoesNotFollowSelection() {
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        defer { live.shutdown() }
        let remote = live.outputs.addAltView(); live.refreshPreferences()
        let manager = ManageOutputsController(live: live); manager.discoveryEnabled = false; _ = manager.view
        manager.selectDestination(remote)
        let original = live.outputs.destination(remote)!
        manager.controlTextDidBeginEditing(.init(name: NSControl.textDidBeginEditingNotification, object: manager.nameField))
        manager.nameField.stringValue = "   "
        manager.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: manager.nameField))
        XCTAssertEqual(live.outputs.destination(remote), original)
        XCTAssertEqual(manager.nameField.stringValue, original.name)
        let visibleLabels = descendants(manager.view).compactMap { $0 as? NSTextField }
        XCTAssertTrue(visibleLabels.contains { $0.stringValue == "Use a name up to 80 characters and a valid assignment." },
                      "AltView destinations need the same visible name validation as native destinations")
        let section = manager.section
        section.selectedSegment = 1
        NSApp.sendAction(section.action!, to: section.target, from: section)
        section.selectedSegment = 0
        NSApp.sendAction(section.action!, to: section.target, from: section)
        XCTAssertFalse(descendants(manager.view).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue == "Use a name up to 80 characters and a valid assignment."
        }, "A previous destination's error must not follow a section change")
    }
    func testAudienceAndLowerThirdCanOptIntoStandbyClockWithoutProjection() {
        for profile in [NativeOutputProfile.audience, .lowerThird] {
            let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [self.monitor(1)] }))
            defer { live.shutdown() }; live.nativeWindowFactory = { _, _, _ in nil }
            let id = live.outputs.destinations[0].id
            assign(live.outputs, id, to: monitor(1), profile: profile.id)
            let manager = ManageOutputsController(live: live); _ = manager.view; manager.selectDestination(id)
            XCTAssertFalse(descendants(manager.view).compactMap { $0 as? NSButton }.contains { $0.title == "Show Standby Clock" })
            XCTAssertEqual(manager.standbyClockButton.state, .off, "Confidence is the only clock-on default")
            manager.standbyClockButton.performClick(nil)
            XCTAssertEqual(live.nativeOutputs[id]?.appearance.profile.standby, .clock)
            XCTAssertNil(live.projector.projection); XCTAssertNil(live.source); XCTAssertFalse(live.windowOpened)
            manager.standbyClockButton.performClick(nil)
            XCTAssertNil(live.nativeOutputs[id]); XCTAssertEqual(live.outputs.profile(profile.id)?.standby, .hidden)
        }
    }
    func testVersionedMigrationPreservesAppearanceMonitorAndAltViewWithoutCompetingBindings() throws {
        let defaults = defaults(), screen = monitor(1)
        defaults.set(137.0, forKey: AppDefaultsKey.fontSizeVerse); defaults.set(47.0, forKey: AppDefaultsKey.fontSizeVerseRef)
        defaults.set(61.0, forKey: AppDefaultsKey.projectorPadding); defaults.set("right", forKey: AppDefaultsKey.projectorTextAlignment)
        defaults.set("rightToLeft", forKey: AppDefaultsKey.projectorReadingDirection); defaults.set(true, forKey: AppDefaultsKey.projectorDualLayoutVertical)
        defaults.set(false, forKey: AppDefaultsKey.projectorShowTranslationInfo); defaults.set(true, forKey: AppDefaultsKey.transparentBackground)
        defaults.set(screen.id, forKey: AppDefaultsKey.projectorScreenDisplayID)
        var receiver = AltViewDestination(name: "This Mac", host: "127.0.0.1", port: 54321); receiver.localReceiverID = UUID()
        defaults.set(try JSONEncoder().encode(receiver), forKey: AppDefaultsKey.altViewDestination); defaults.set("future.layout", forKey: AppDefaultsKey.altViewTemplate)
        let displays = ProjectionDisplayManager(defaults: defaults, displays: { [screen] }), store = OutputConfigurationStore(defaults: defaults, displays: displays)
        let audience = store.profile(NativeOutputProfile.audienceID)!
        XCTAssertEqual([audience.verse.size, audience.reference.size, audience.padding], [137, 47, 61])
        XCTAssertEqual(audience.alignment, .right); XCTAssertEqual(audience.readingDirection, .rightToLeft)
        XCTAssertEqual(audience.translationLayout, .vertical); XCTAssertTrue(audience.transparent); XCTAssertFalse(audience.showTranslationNames)
        XCTAssertEqual(store.destinations.filter { $0.native != nil }.count, 1); XCTAssertTrue(store.destinations[0].enabled)
        XCTAssertEqual(store.destinations[0].native?.monitor, screen.target)
        XCTAssertEqual(store.destinations[1].altView?.receiver, receiver); XCTAssertEqual(store.destinations[1].altView?.receiverID, receiver.localReceiverID)
        XCTAssertEqual(store.destinations[1].altView?.template?.rawValue, "future.layout")
        defaults.set(50, forKey: AppDefaultsKey.fontSizeVerse); defaults.set("left", forKey: AppDefaultsKey.projectorTextAlignment)
        let restored = OutputConfigurationStore(defaults: defaults, displays: displays)
        XCTAssertEqual(restored.profile(audience.id), audience, "Legacy keys never override a migrated profile")
    }
    func testAudienceMigrationUsesTheFormerProjectorDarkPaletteWithLightOperatorAppearance() throws {
        let preferences = defaults(), displays = ProjectionDisplayManager(displays: { [] })
        var migrated: NativeOutputProfile?
        try XCTUnwrap(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
            migrated = OutputConfigurationStore(defaults: preferences, displays: displays).profile(NativeOutputProfile.audienceID)
        }
        var reference: OutputColor?, names: OutputColor?
        try XCTUnwrap(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            reference = OutputColor(NSColor.controlAccentColor.withAlphaComponent(0.95))
            names = OutputColor(NSColor.systemTeal.withAlphaComponent(0.92))
        }
        XCTAssertEqual(migrated?.referenceColor, reference)
        XCTAssertEqual(migrated?.translationNamesColor, names, "The old projector forced dark appearance independently of the operator")
    }
    func testMissingLegacyRuntimeIDCannotBeGuessedOnLaterLaunchAndNoneNeverFallsBack() {
        for old: Any in [0, 999, true, "invalid"] {
            let defaults = defaults(); defaults.set(old, forKey: AppDefaultsKey.projectorScreenDisplayID)
            let first = ProjectionDisplayManager(defaults: defaults, displays: { [self.monitor(1)] })
            let saved = OutputConfigurationStore(defaults: defaults, displays: first).destinations[0].native?.monitor
            let reused = ProjectionMonitor(id: 999, identity: monitor(2).identity, name: "TV", frame: monitor(2).frame)
            let second = ProjectionDisplayManager(defaults: defaults, displays: { [reused] })
            let restored = OutputConfigurationStore(defaults: defaults, displays: second)
            XCTAssertEqual(restored.destinations[0].native?.monitor, saved)
            XCTAssertNil(saved.flatMap(second.resolve))
        }
        let defaults = defaults(), displays = ProjectionDisplayManager(displays: { [self.monitor(1)] })
        let store = OutputConfigurationStore(defaults: defaults, displays: displays)
        XCTAssertNil(store.destinations[0].native?.monitor)
    }
    func testCorruptAndFutureConfigurationRemainRecoverableAndNeverEnableOutput() throws {
        let valid = OutputConfiguration(profiles: [.audience], destinations: [])
        var future = valid; future.version = 99
        for data in [Data("broken".utf8), try JSONEncoder().encode(future)] {
            let defaults = defaults(); defaults.set(data, forKey: AppDefaultsKey.outputConfiguration)
            let store = OutputConfigurationStore(defaults: defaults, displays: ProjectionDisplayManager(displays: { [] }))
            XCTAssertFalse(store.canEdit); XCTAssertTrue(store.destinations.allSatisfy { !$0.enabled })
            store.updateProfile(.lowerThird); XCTAssertEqual(defaults.data(forKey: AppDefaultsKey.outputConfiguration), data)
            store.restoreDefaults()
            XCTAssertTrue(store.canEdit)
            let backups = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(AppDefaultsKey.outputRecoveryPrefix) }
            XCTAssertEqual(backups.count, 1); XCTAssertEqual(backups.first?.value as? Data, data)
        }
    }
    func testProfilesSelectOnlyCommittedComponentsAndCollapseMissingSecondary() {
        let data = projection().data
        let audience = NativeOutputProfile.audience, confidence = NativeOutputProfile.confidence, lower = NativeOutputProfile.lowerThird
        XCTAssertEqual(confidence.components(in: data).secondary, "Committed secondary")
        XCTAssertEqual(confidence.components(in: data).secondaryName, "English · NLT")
        XCTAssertEqual(audience.components(in: data).reference, "John 3:16")
        XCTAssertNil(lower.components(in: data).secondary)
        for secondary: String? in [nil, " \n", "\u{200c}"] {
            let components = confidence.components(in: projection(secondary: secondary).data)
            XCTAssertNil(components.secondary); XCTAssertNil(components.secondaryName)
        }
        var onlySecondary = confidence; onlySecondary.showPrimary = false; onlySecondary.showReference = false
        XCTAssertNil(onlySecondary.components(in: data).primary); XCTAssertNil(onlySecondary.components(in: data).primaryName)
        XCTAssertEqual(onlySecondary.components(in: data).secondary, "Committed secondary")
        XCTAssertNil(onlySecondary.components(in: data).reference)
    }
    func testDuplicationEditsIndependentlyAndRoundTrips() throws {
        let defaults = defaults(), displays = ProjectionDisplayManager(displays: { [] })
        let live = LiveProjectionController(defaults: defaults, projectionDisplays: displays)
        defer { live.shutdown() }
        let store = live.outputs, original = store.profiles[0]
        let manager = ManageOutputsController(live: live); _ = manager.view; manager.selectProfile(original.id)
        let assignments = store.destinations
        manager.addProfileButton.performClick(nil)
        let duplicateID = try XCTUnwrap(manager.profileEditor?.profileID)
        XCTAssertNotEqual(duplicateID, original.id); XCTAssertEqual(store.destinations, assignments)
        var duplicate = store.profile(duplicateID)!; duplicate.verse.size = 44; duplicate.background = .chromaGreen; store.updateProfile(duplicate)
        XCTAssertEqual(store.profile(original.id), original)
        let encoded = try JSONEncoder().encode(store.configuration); defaults.set(encoded, forKey: AppDefaultsKey.outputConfiguration)
        let restored = OutputConfigurationStore(defaults: defaults, displays: displays)
        XCTAssertEqual(restored.profile(duplicateID), duplicate)
    }
    func testProfilesWithTheSameNameRemainIndividuallySelectable() throws {
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        defer { live.shutdown() }
        let firstCopy = try XCTUnwrap(live.outputs.duplicateProfile(NativeOutputProfile.audienceID))
        let secondCopy = try XCTUnwrap(live.outputs.duplicateProfile(NativeOutputProfile.audienceID))
        let id = live.outputs.destinations[0].id
        assign(live.outputs, id, to: nil, profile: firstCopy)
        let manager = ManageOutputsController(live: live); _ = manager.view
        let copies = manager.profilePicker.itemArray.filter { $0.title == "Audience Copy" }
        manager.profilePicker.menu?.update()
        XCTAssertTrue(copies.allSatisfy(\.isEnabled))
        XCTAssertEqual(Set(copies.compactMap { $0.representedObject as? UUID }), [firstCopy, secondCopy])
        XCTAssertEqual(manager.profilePicker.selectedItem?.representedObject as? UUID, firstCopy)
        let secondItem = try XCTUnwrap(copies.first { $0.representedObject as? UUID == secondCopy })
        manager.profilePicker.select(secondItem)
        NSApp.sendAction(manager.profilePicker.action!, to: manager.profilePicker.target, from: manager.profilePicker)
        XCTAssertEqual(live.outputs.destination(id)?.native?.profileID, secondCopy)
        manager.profilePicker.select(try XCTUnwrap(copies.first { $0.representedObject as? UUID == firstCopy }))
        NSApp.sendAction(manager.profilePicker.action!, to: manager.profilePicker.target, from: manager.profilePicker)
        XCTAssertEqual(live.outputs.destination(id)?.native?.profileID, firstCopy)
    }
    func testMonitorAndReceiverConflictsDisabledAndMissingAssignments() {
        let inventory = OutputInventory([monitor(1), monitor(2)])
        let manager = ProjectionDisplayManager(displays: { inventory.monitors }), store = OutputConfigurationStore(defaults: defaults(), displays: manager)
        let first = store.destinations[0].id, second = store.addNative()
        assign(store, first, to: inventory.monitors[0], profile: NativeOutputProfile.audienceID)
        var conflicting = store.destination(second)!; conflicting.enabled = true; conflicting.assignment = store.destination(first)!.assignment
        XCTAssertNotNil(store.update(conflicting))
        conflicting.enabled = false; XCTAssertNil(store.update(conflicting))
        inventory.monitors = []; manager.refresh(); conflicting.enabled = true; XCTAssertNil(store.update(conflicting), "Disconnected assignments reserve no monitor")
        inventory.monitors = [monitor(1)]; manager.refresh()
        XCTAssertNotNil(store.conflict(for: store.destination(first)!)); XCTAssertNotNil(store.conflict(for: store.destination(second)!))
        var renamed = store.destination(second)!; renamed.name = "Retained assignment"
        XCTAssertNil(store.update(renamed), "A returning conflict must not block ordinary name/profile editing")
        let remote1 = store.addAltView(), remote2 = store.addAltView(), receiver = AltViewDestination(name: "Receiver", host: "receiver.local", port: 54321), identity = UUID()
        var a = store.destination(remote1)!; a.enabled = true; a.assignment = .altView(.init(receiver: receiver, receiverID: identity)); XCTAssertNil(store.update(a))
        var b = store.destination(remote2)!; b.enabled = true; b.assignment = .altView(.init(receiver: .init(name: "Alias", host: "192.0.2.1", port: 54321), receiverID: identity))
        XCTAssertNotNil(store.update(b)); b.enabled = false; XCTAssertNil(store.update(b)); XCTAssertEqual(store.destination(remote2)?.altView?.receiverID, identity)
        store.receiverIsAvailable = { _ in false }; b.enabled = true
        XCTAssertNil(store.update(b), "Missing receivers reserve no ownership")
        store.receiverIsAvailable = { _ in true }
        XCTAssertNotNil(store.conflict(for: store.destination(remote1)!)); XCTAssertNotNil(store.conflict(for: store.destination(remote2)!))
    }
    func testIndependentWindowsFullFramePartialLossBlankStopAndSleep() async throws {
        _ = NSApplication.shared
        let inventory = OutputInventory([monitor(1), monitor(2)])
        let displays = ProjectionDisplayManager(displays: { inventory.monitors }), defaults = defaults()
        var begins = 0, ends = 0
        let sleep = ProjectionSleepPrevention(beginActivity: { _, _ in begins += 1; return NSObject() }, endActivity: { _ in ends += 1 })
        let live = LiveProjectionController(defaults: defaults, projectionDisplays: displays, sleepPrevention: sleep)
        defer { live.shutdown() }
        let audience = live.outputs.destinations[0].id, confidence = live.outputs.addNative()
        assign(live.outputs, audience, to: monitor(1), profile: NativeOutputProfile.audienceID)
        assign(live.outputs, confidence, to: monitor(2), profile: NativeOutputProfile.confidenceID)
        live.nativeWindowFactory = { _, _, _ in
            let window = OutputWindow(contentRect: .init(x: -10000, y: -10000, width: 10, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; return window
        }
        live.showStandby(confidence)
        XCTAssertFalse(live.windowOpened); XCTAssertNil(live.source); XCTAssertNil(live.projector.projectionOwner)
        XCTAssertEqual(live.nativeOutputs[confidence]?.window?.frame, monitor(2).frame); XCTAssertEqual(begins, 1)
        live.publishRow(projection(), from: UUID()); XCTAssertEqual(live.nativeOutputs.count, 2)
        for (id, number) in [(audience, 1), (confidence, 2)] { XCTAssertEqual(live.nativeOutputs[id]?.window?.frame, monitor(number).frame) }
        XCTAssertEqual(begins, 1)
        let revision = live.projector.revision
        var profile = live.outputs.profile(NativeOutputProfile.confidenceID)!; profile.verse.size = 55; profile.transparent = true
        live.outputs.updateProfile(profile); live.refreshPreferences()
        XCTAssertEqual(live.nativeOutputs[confidence]?.appearance.profile.verse.size, 55)
        XCTAssertEqual(live.nativeOutputs[audience]?.appearance.profile.verse.size, 100)
        XCTAssertEqual(live.projector.revision, revision, "Appearance editing cannot publish")
        live.toggleBlank(); XCTAssertTrue(live.projector.isBlanked); XCTAssertEqual(live.projector.projectorViewData, projection().data)
        inventory.monitors = [monitor(2)]; displays.refresh(); await settle()
        XCTAssertNil(live.nativeOutputs[audience]); XCTAssertNotNil(live.nativeOutputs[confidence]); XCTAssertTrue(live.windowOpened)
        XCTAssertEqual(ends, 0); XCTAssertEqual(live.outputs.destination(audience)?.native?.monitor, monitor(1).target)
        inventory.monitors = [monitor(1), monitor(2)]; displays.refresh(); await settle()
        XCTAssertNil(live.nativeOutputs[audience], "Reconnect does not reopen")
        live.closeProjector(); await settle(); XCTAssertNil(live.projector.projectionOwner); XCTAssertFalse(live.windowOpened)
        XCTAssertNotNil(live.nativeOutputs[confidence], "Stop retains Confidence standby")
        XCTAssertEqual(ends, 0); live.closeNativeOutput(confidence); XCTAssertEqual(ends, 1)
        live.publishRow(projection(), from: UUID()); XCTAssertEqual(live.nativeOutputs.count, 2)
        XCTAssertEqual(begins, 2); live.shutdown(); XCTAssertEqual(ends, 2)
    }
    func testLaunchStartsOnlyConfiguredClocksWithoutScriptureAndReconnectRequiresExplicitReopening() async throws {
        _ = NSApplication.shared
        let inventory = OutputInventory([monitor(1), monitor(2), monitor(3)])
        let displays = ProjectionDisplayManager(displays: { inventory.monitors }), savedDefaults = defaults()
        let saved = OutputConfigurationStore(defaults: savedDefaults, displays: displays)
        let audience = saved.destinations[0].id, confidence = saved.addNative(), disabled = saved.addNative(), missing = saved.addNative()
        assign(saved, audience, to: monitor(1), profile: NativeOutputProfile.audienceID)
        assign(saved, confidence, to: monitor(2), profile: NativeOutputProfile.confidenceID)
        assign(saved, disabled, to: monitor(3), profile: NativeOutputProfile.confidenceID, enabled: false)
        assign(saved, missing, to: monitor(4), profile: NativeOutputProfile.confidenceID)
        var begins = 0, ends = 0
        let sleep = ProjectionSleepPrevention(beginActivity: { _, _ in begins += 1; return NSObject() }, endActivity: { _ in ends += 1 })
        let live = LiveProjectionController(defaults: savedDefaults, projectionDisplays: displays, sleepPrevention: sleep)
        defer { live.shutdown() }
        live.nativeWindowFactory = { _, _, _ in
            let window = OutputWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; return window
        }
        live.restoreOutputConnections()
        XCTAssertEqual(Set(live.nativeOutputs.keys), [confidence])
        let window = try XCTUnwrap(live.nativeOutputs[confidence]?.window as? OutputWindow)
        XCTAssertEqual(window.frame, monitor(2).frame); XCTAssertEqual(window.frontCount, 1)
        XCTAssertFalse(live.windowOpened); XCTAssertNil(live.source); XCTAssertNil(live.projector.projectionOwner)
        XCTAssertNil(live.projector.projection); XCTAssertEqual(begins, 1)
        live.restoreOutputConnections(); XCTAssertEqual(window.frontCount, 1, "Startup runs once")
        inventory.monitors = [monitor(1), monitor(3)]; displays.refresh(); await settle()
        XCTAssertTrue(live.nativeOutputs.isEmpty); XCTAssertEqual(ends, 1)
        inventory.monitors = [monitor(1), monitor(2), monitor(3), monitor(4)]; displays.refresh(); await settle()
        live.refreshPreferences(); live.restoreOutputConnections()
        XCTAssertTrue(live.nativeOutputs.isEmpty, "Neither returning nor initially missing monitors reopen through passive work")
        live.showStandby(confidence)
        XCTAssertNotNil(live.nativeOutputs[confidence]); XCTAssertEqual(begins, 2)
        live.closeNativeOutput(confidence); live.restoreOutputConnections()
        XCTAssertTrue(live.nativeOutputs.isEmpty); XCTAssertEqual(ends, 2)
        let manager = ManageOutputsController(live: live); _ = manager.view; manager.selectDestination(confidence)
        manager.enabledButton.performClick(nil); manager.enabledButton.performClick(nil)
        XCTAssertNotNil(live.nativeOutputs[confidence], "Explicit re-enabling opens standby without an extra clock action")
        XCTAssertEqual(live.outputs.destination(confidence)?.native?.monitor, monitor(2).target)
        XCTAssertNil(live.projector.projectionOwner); XCTAssertEqual(begins, 3)
    }
    func testManageOutputsClockCheckboxStartsBeforeVerseAndNeverChangesCommittedOrRemoteContent() async throws {
        _ = NSApplication.shared
        let savedDefaults = defaults(), sender = OutputSender()
        let live = LiveProjectionController(defaults: savedDefaults, projectionDisplays: ProjectionDisplayManager(displays: { [self.monitor(1), self.monitor(2)] }),
            altViewServiceFactory: { saved, discovery in
                AltViewProjectionService(destination: saved.receiver, template: saved.template, store: OutputPairings(), discovery: discovery) { sender.callback = $0; return sender }
            })
        defer { live.shutdown() }
        live.nativeWindowFactory = { _, _, _ in nil }
        let audience = live.outputs.destinations[0].id, confidence = live.outputs.addNative(), remote = live.outputs.addAltView()
        assign(live.outputs, audience, to: monitor(1), profile: NativeOutputProfile.audienceID)
        assign(live.outputs, confidence, to: nil, profile: NativeOutputProfile.confidenceID, enabled: false)
        XCTAssertNil(live.connectAltView(remote, to: .init(name: "Receiver", host: "receiver.local", port: 54321), code: "ABCD2345"))
        try await eventually { sender.connectionID != nil }; sender.welcome(); await settle()
        let manager = ManageOutputsController(live: live); manager.discoveryEnabled = false; _ = manager.view
        manager.selectDestination(confidence)
        XCTAssertEqual(manager.standbyClockButton.state, .on)
        manager.enabledButton.performClick(nil)
        XCTAssertNil(live.nativeOutputs[confidence], "None never selects a fallback screen")
        let monitorItem = try XCTUnwrap(manager.monitorPicker.itemArray.first { ($0.representedObject as? ProjectionMonitorTarget)?.identity == self.monitor(2).identity })
        manager.monitorPicker.select(monitorItem)
        NSApp.sendAction(manager.monitorPicker.action!, to: manager.monitorPicker.target, from: manager.monitorPicker)
        XCTAssertNotNil(live.nativeOutputs[confidence], "Assigning an enabled Confidence monitor starts its empty clock")
        XCTAssertNil(live.projector.projectionOwner); XCTAssertNil(live.source); XCTAssertFalse(live.windowOpened)
        manager.standbyClockButton.performClick(nil)
        XCTAssertNil(live.nativeOutputs[confidence]); XCTAssertEqual(live.outputs.profile(NativeOutputProfile.confidenceID)?.standby, .hidden)
        manager.standbyClockButton.performClick(nil)
        XCTAssertNotNil(live.nativeOutputs[confidence]); XCTAssertTrue(sender.submissions.isEmpty)
        manager.selectProfile(NativeOutputProfile.confidenceID)
        try XCTUnwrap(manager.profileEditor).standbyClockButton.performClick(nil)
        XCTAssertNil(live.nativeOutputs[confidence], "The profile editor uses the same clock setting")
        manager.selectDestination(confidence); XCTAssertEqual(manager.standbyClockButton.state, .off)
        manager.standbyClockButton.performClick(nil)
        let reopened = OutputConfigurationStore(defaults: savedDefaults, displays: live.projectionDisplays)
        XCTAssertEqual(reopened.profile(NativeOutputProfile.confidenceID)?.standby, .clock)
        live.publishRow(projection(), from: UUID())
        let source = live.source, revision = live.projector.revision, data = live.projector.projectorViewData, count = sender.submissions.count
        manager.reload(); manager.standbyClockButton.performClick(nil)
        XCTAssertNotNil(live.nativeOutputs[confidence], "Turning off the clock must retain live scripture")
        XCTAssertNotNil(live.nativeOutputs[audience]); XCTAssertEqual(live.projector.projectorViewData, data)
        XCTAssertEqual(live.projector.revision, revision); XCTAssertEqual(live.source, source); XCTAssertEqual(sender.submissions.count, count)
        live.toggleBlank(); manager.reload()
        let blankRevision = live.projector.revision, blankCount = sender.submissions.count
        manager.standbyClockButton.performClick(nil)
        XCTAssertTrue(live.projector.isBlanked); XCTAssertEqual(live.projector.projectorViewData, data)
        XCTAssertEqual(live.projector.revision, blankRevision); XCTAssertEqual(sender.submissions.count, blankCount)
        live.closeProjector(); await settle()
        XCTAssertNotNil(live.nativeOutputs[confidence]); XCTAssertNil(live.source)
        manager.reload(); manager.standbyClockButton.performClick(nil)
        XCTAssertNil(live.nativeOutputs[confidence], "Clock off after Stop releases the standalone window")
    }
    func testClockOffDuringVersePreparationDoesNotRevokeThePendingProjection() async {
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [self.monitor(1)] }))
        defer { live.shutdown() }; live.nativeWindowFactory = { _, _, _ in nil }
        let confidence = live.outputs.destinations[0].id
        assign(live.outputs, confidence, to: monitor(1), profile: NativeOutputProfile.confidenceID)
        live.showStandby(confidence)
        let model = VerseTargetModel(), next = projection("Prepared while clock was hidden"), tab = UUID()
        let token = live.beginIntent(from: tab, sources: next.sources, using: model)
        let manager = ManageOutputsController(live: live); _ = manager.view; manager.selectDestination(confidence)
        manager.standbyClockButton.performClick(nil)
        XCTAssertTrue(live.isProjecting); XCTAssertNil(live.projector.projectionOwner)
        live.publish(next, intent: token)
        XCTAssertEqual(live.projector.projectorViewData.primaryText, "Prepared while clock was hidden")
        XCTAssertEqual(live.source?.tabID, tab); XCTAssertNotNil(live.nativeOutputs[confidence])
        XCTAssertEqual(live.outputs.profile(NativeOutputProfile.confidenceID)?.standby, .hidden)
        live.closeProjector(); await settle(); XCTAssertNil(live.nativeOutputs[confidence])
    }
    func testCancelingPreparationClosesAnEmptyOutputWhoseClockWasTurnedOff() async {
        _ = NSApplication.shared
        var begins = 0, ends = 0
        let sleep = ProjectionSleepPrevention(beginActivity: { _, _ in begins += 1; return NSObject() }, endActivity: { _ in ends += 1 })
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [self.monitor(1)] }), sleepPrevention: sleep)
        defer { live.shutdown() }
        live.nativeWindowFactory = { _, _, _ in
            let window = OutputWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; return window
        }
        let id = live.outputs.destinations[0].id, tab = UUID(), model = VerseTargetModel()
        assign(live.outputs, id, to: monitor(1), profile: NativeOutputProfile.confidenceID)
        live.showStandby(id)
        let token = live.beginIntent(from: tab, sources: projection().sources, using: model)
        var profile = live.outputs.profile(NativeOutputProfile.confidenceID)!
        profile.standby = .hidden; XCTAssertNil(live.outputs.updateProfile(profile)); live.refreshPreferences()
        await settle()
        XCTAssertNotNil(live.nativeOutputs[id], "An explicit verse still preparing retains its window")
        live.detachTab(tab); await settle()
        XCTAssertFalse(live.isProjecting); XCTAssertNil(live.projector.projectionOwner)
        XCTAssertNil(live.nativeOutputs[id], "After cancellation an empty output with clock off must close")
        XCTAssertFalse(live.projectionDisplays.isLocked); XCTAssertEqual(begins, 1); XCTAssertEqual(ends, 1)
        live.publish(projection(), intent: token)
        XCTAssertNil(live.projector.projectionOwner); XCTAssertNil(live.nativeOutputs[id])
    }
    func testRasterRenderingKeepsProfilesIndependentAndConfidenceClockVisibleOnBlank() throws {
        let model = ProjectorViewModel(); model.project(projection(secondary: nil).data, owner: projection().owner)
        func bitmap(_ profile: NativeOutputProfile) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: ProjectorView(profile: profile).environmentObject(model).frame(width: 800, height: 450))
            renderer.proposedSize = .init(width: 800, height: 450)
            return try XCTUnwrap(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        }
        let audience = try bitmap(.audience), lower = try bitmap(.lowerThird)
        let black = try XCTUnwrap(audience.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        let green = try XCTUnwrap(lower.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(black.greenComponent, 0.05); XCTAssertGreaterThan(green.greenComponent, 0.95)
        XCTAssertLessThan(green.redComponent, 0.05)
        func brightPixels(_ image: NSBitmapImageRep) -> Int {
            var count = 0
            for y in stride(from: 0, to: image.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: image.pixelsWide, by: 4) {
                    if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent > 0.7 { count += 1 }
                }
            }
            return count
        }
        model.toggleBlank()
        XCTAssertEqual(brightPixels(try bitmap(.audience)), 0)
        XCTAssertGreaterThan(brightPixels(try bitmap(.confidence)), 50, "Blank confidence retains the centered clock")
        var clockOff = NativeOutputProfile.confidence; clockOff.standby = .hidden
        XCTAssertEqual(brightPixels(try bitmap(clockOff)), 0, "The clock checkbox can hide the blanked clock without exposing scripture")
        model.clearProjection()
        XCTAssertGreaterThan(brightPixels(try bitmap(.confidence)), 50, "Empty confidence retains the clock")
        XCTAssertEqual(brightPixels(try bitmap(clockOff)), 0)
    }
    func testClosingDestinationRevokesOnlyItsPendingOpeningAndReconnectCannotReopenIt() async {
        let inventory = OutputInventory([monitor(1), monitor(2)])
        let displays = ProjectionDisplayManager(displays: { inventory.monitors })
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: displays)
        defer { live.shutdown() }; live.nativeWindowFactory = { _, _, _ in nil }
        let first = live.outputs.destinations[0].id, second = live.outputs.addNative()
        assign(live.outputs, first, to: monitor(1), profile: NativeOutputProfile.audienceID)
        live.publishRow(projection(), from: UUID())
        assign(live.outputs, second, to: monitor(2), profile: NativeOutputProfile.audienceID)
        let model = VerseTargetModel(), next = projection("Pending scripture"), tab = UUID()
        let token = live.beginIntent(from: tab, sources: next.sources, using: model)
        live.closeNativeOutput(first)
        inventory.monitors = [monitor(2)]; displays.refresh()
        await settle()
        XCTAssertTrue(live.isProjecting, "Another ready destination retains its preparation")
        XCTAssertNil(live.projector.projectionOwner)
        inventory.monitors = [monitor(1), monitor(2)]; displays.refresh()
        live.publish(next, intent: token)
        XCTAssertNil(live.nativeOutputs[first], "An older pending intent cannot reopen a closed/reconnected destination")
        XCTAssertNotNil(live.nativeOutputs[second]); XCTAssertEqual(live.projector.projectorViewData.primaryText, "Pending scripture")
        live.publishRow(next, from: tab)
        XCTAssertNotNil(live.nativeOutputs[first], "A fresh explicit projection reopens it")
    }
    func testInitialPendingNativeOpeningIsInvalidatedByMonitorLossOrReassignment() async {
        for reassign in [false, true] {
            let inventory = OutputInventory([monitor(1), monitor(2)])
            let displays = ProjectionDisplayManager(displays: { inventory.monitors })
            let live = LiveProjectionController(defaults: defaults(), projectionDisplays: displays)
            defer { live.shutdown() }; live.nativeWindowFactory = { _, _, _ in nil }
            let id = live.outputs.destinations[0].id
            assign(live.outputs, id, to: monitor(1), profile: NativeOutputProfile.audienceID)
            let model = VerseTargetModel(), next = projection(), tab = UUID()
            let token = live.beginIntent(from: tab, sources: next.sources, using: model)
            if reassign { assign(live.outputs, id, to: monitor(2), profile: NativeOutputProfile.audienceID) }
            else {
                inventory.monitors = [monitor(2)]; displays.refresh()
                inventory.monitors = [monitor(1), monitor(2)]; displays.refresh()
            }
            live.publish(next, intent: token); await settle()
            XCTAssertTrue(live.nativeOutputs.isEmpty, "A stale intent cannot open a reconnected or newly assigned monitor")
            XCTAssertNil(live.projector.projectionOwner)
            live.publishRow(next, from: tab)
            XCTAssertNotNil(live.nativeOutputs[id], "Fresh explicit projection authorizes the current assignment")
        }
    }
    func testPendingNativeOpeningCannotRegainPermissionByRestoringItsAssignment() async {
        for disable in [false, true] {
            let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [self.monitor(1), self.monitor(2)] }))
            defer { live.shutdown() }; live.nativeWindowFactory = { _, _, _ in nil }
            let id = live.outputs.destinations[0].id, other = live.outputs.addNative()
            assign(live.outputs, id, to: monitor(1), profile: NativeOutputProfile.audienceID)
            // A separate destination keeps the pending projection eligible.
            assign(live.outputs, other, to: monitor(2), profile: NativeOutputProfile.audienceID)
            let next = projection("Pending scripture"), model = VerseTargetModel(), tab = UUID()
            let token = live.beginIntent(from: tab, sources: next.sources, using: model)
            assign(live.outputs, id, to: disable ? monitor(1) : nil, profile: NativeOutputProfile.audienceID, enabled: !disable)
            assign(live.outputs, id, to: monitor(1), profile: NativeOutputProfile.audienceID)
            live.publish(next, intent: token); await settle()
            XCTAssertNil(live.nativeOutputs[id], "Restoring a previous assignment or enable state cannot revive an older opening permission")
            XCTAssertNotNil(live.nativeOutputs[other]); XCTAssertEqual(live.projector.projectorViewData, next.data)
            live.publishRow(next, from: tab)
            XCTAssertNotNil(live.nativeOutputs[id], "A fresh explicit projection authorizes the restored assignment")
        }
    }
    func testRemoteFailureCannotCancelPendingNativeProjection() async throws {
        let client = OutputSender(), displays = ProjectionDisplayManager(displays: { [self.monitor(1)] })
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: displays, altViewServiceFactory: { saved, discovery in
            AltViewProjectionService(destination: saved.receiver, store: OutputPairings(), discovery: discovery) { client.callback = $0; return client }
        })
        defer { live.shutdown() }; live.nativeWindowFactory = { _, _, _ in nil }
        let nativeID = live.outputs.destinations[0].id
        assign(live.outputs, nativeID, to: monitor(1), profile: NativeOutputProfile.audienceID, enabled: false)
        let remoteID = live.outputs.addAltView(); live.refreshPreferences()
        XCTAssertNil(live.connectAltView(remoteID, to: .init(name: "Remote", host: "receiver.local", port: 54321), code: "ABCD2345"))
        try await eventually { client.connectionID != nil }; client.welcome()
        live.publishRow(projection(), from: UUID())
        assign(live.outputs, nativeID, to: monitor(1), profile: NativeOutputProfile.audienceID)
        let next = projection("Native wins"), model = VerseTargetModel(), tab = UUID()
        let token = live.beginIntent(from: tab, sources: next.sources, using: model)
        client.callback?(.init(connectionID: client.connectionID, failureReason: "Remote failure"))
        live.refreshPreferences(); await settle()
        XCTAssertTrue(live.isProjecting); XCTAssertNil(live.projector.projectionOwner)
        live.publish(next, intent: token)
        XCTAssertEqual(live.projector.projectorViewData.primaryText, "Native wins")
        XCTAssertNotNil(live.nativeOutputs[nativeID]); XCTAssertEqual(live.source?.tabID, tab)
    }
    func testNativeWindowHostingUsesFullScreenFrameAndOperatorWindowLevel() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first), model = ProjectorViewModel()
        let window = ProjectorView(profile: .confidence).environmentObject(model).makeProjectorWindow(with: "Clock", on: screen)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame, screen.frame); XCTAssertEqual(window.contentView?.bounds.size, screen.frame.size)
        XCTAssertEqual(window.level, .screenSaver); XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]))
    }
    func testRemoteOnlyManageOutputsConnectRestoreBlankStopAndFailuresAreIndependent() async throws {
        _ = NSApplication.shared
        let defaults = defaults(), store = OutputPairings(), first = OutputSender(), second = OutputSender(), browser = OutputDiscovery()
        let discovery = AltViewDiscoveryService(factory: { _ in browser })
        var clients = [first, second]
        let live = LiveProjectionController(defaults: defaults, projectionDisplays: ProjectionDisplayManager(displays: { [] }), discovery: discovery, altViewServiceFactory: { saved, discovery in
            let sender = clients.removeFirst()
            return AltViewProjectionService(destination: saved.receiver, template: saved.template, store: store, discovery: discovery) { sender.callback = $0; return sender }
        })
        defer { live.shutdown() }
        let id1 = live.outputs.addAltView(), id2 = live.outputs.addAltView(); live.refreshPreferences()
        let manager = ManageOutputsController(live: live); manager.discoveryEnabled = false; _ = manager.view
        manager.selectDestination(id1)
        let receiver1 = AltViewDestination(name: "One", host: "receiver1.local", port: 54321), receiver2 = AltViewDestination(name: "Two", host: "receiver2.local", port: 54321)
        XCTAssertNil(live.connectAltView(id1, to: receiver1, code: "ABCD2345")); XCTAssertNil(live.connectAltView(id2, to: receiver2, code: "ABCD2345"))
        try await eventually { first.connectionID != nil && second.connectionID != nil }
        first.welcome(); second.welcome(); await settle()
        XCTAssertTrue(first.submissions.isEmpty && second.submissions.isEmpty, "Connect Only cannot publish")
        XCTAssertFalse(live.windowOpened); live.publishRow(projection(), from: UUID())
        XCTAssertTrue(live.windowOpened); XCTAssertTrue(live.nativeOutputs.isEmpty)
        XCTAssertEqual(first.submissions.last?.content?.confidence?.secondary?.body, "Committed secondary")
        XCTAssertEqual(first.submissions.last?.content, second.submissions.last?.content)
        let firstIntent = first.submissions.last?.intent
        live.toggleBlank(); XCTAssertEqual(first.submissions.last?.content?.visible, false); XCTAssertEqual(first.submissions.last?.intent, firstIntent)
        first.callback?(.init(connectionID: first.connectionID, failureReason: "Authentication failed")); await settle()
        XCTAssertTrue(live.windowOpened, "Another destination retains output")
        let token = live.beginIntent(from: UUID(), sources: projection().sources, using: VerseTargetModel())
        live.publish(projection("Refreshed"), intent: token, preserveBlanking: true)
        XCTAssertEqual(second.submissions.last?.content?.body, "Refreshed"); XCTAssertEqual(second.submissions.last?.content?.visible, false)
        live.closeProjector(); await settle(); XCTAssertNil(second.submissions.last?.content); XCTAssertNil(live.projector.projectionOwner)
        manager.selectDestination(id2); manager.remoteEditor?.disconnectButton.performClick(nil)
        XCTAssertFalse(live.altViewServices[id2]!.isEnabled)
        live.restoreOutputConnections(); live.restoreOutputConnections()
        try await eventually { second.connectCount == 2 }
        XCTAssertNil(second.submissions.last?.content, "Restoration cannot republish")
    }
    func testSharedDiscoveryAndAuthenticatedAliasConflictsNeverTakeOwnership() async throws {
        let browser = OutputDiscovery(), discovery = AltViewDiscoveryService(factory: { _ in browser }), defaults = defaults()
        let first = OutputSender(), second = OutputSender(); second.receiverID = first.receiverID
        var clients = [first, second]
        let live = LiveProjectionController(defaults: defaults, projectionDisplays: ProjectionDisplayManager(displays: { [] }), discovery: discovery, altViewServiceFactory: { saved, discovery in
            let sender = clients.removeFirst(); return AltViewProjectionService(destination: saved.receiver, store: OutputPairings(), discovery: discovery) { sender.callback = $0; return sender }
        })
        defer { live.shutdown() }
        let one = live.outputs.addAltView(), two = live.outputs.addAltView(); live.refreshPreferences()
        live.altViewServices[one]?.startDiscovery(); live.altViewServices[two]?.startDiscovery()
        XCTAssertEqual(browser.starts, 1)
        live.altViewServices[one]?.stopDiscovery(); XCTAssertEqual(browser.stops, 0)
        live.altViewServices[two]?.stopDiscovery(); XCTAssertEqual(browser.stops, 1)
        XCTAssertNil(live.connectAltView(one, to: .init(name: "One", host: "receiver.local", port: 54321), code: "ABCD2345"))
        try await eventually { first.connectionID != nil }; first.welcome(); await settle()
        XCTAssertNil(live.connectAltView(two, to: .init(name: "Alias", host: "192.0.2.1", port: 54321), code: "ABCD2345"))
        try await eventually { second.connectionID != nil }
        live.publishRow(projection(), from: UUID()); XCTAssertTrue(second.submissions.isEmpty, "Unknown authenticated identity must be checked before any take")
        second.welcome(); await settle()
        XCTAssertFalse(live.altViewServices[two]!.isEnabled); XCTAssertTrue(second.submissions.isEmpty)
        XCTAssertTrue(live.altViewServices[two]!.pairingNote?.contains("already uses") == true)
    }
    func testDisabledDestinationRefreshIsSilentAndEditingLayoutRetainsNewReceiverAssignment() async throws {
        let client = OutputSender()
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [] }), altViewServiceFactory: { saved, discovery in
            AltViewProjectionService(destination: saved.receiver, template: saved.template, store: OutputPairings(), discovery: discovery) { client.callback = $0; return client }
        })
        defer { live.shutdown() }
        let id = live.outputs.addAltView(); live.refreshPreferences(); await settle()
        let service = live.altViewServices[id]!
        var notifications = 0
        let observation = service.objectWillChange.sink { notifications += 1 }
        for _ in 0..<4 { live.refreshPreferences(); await settle() }
        XCTAssertEqual(notifications, 0, "Disabled destinations must not continuously emit disconnect/status refreshes")
        XCTAssertNil(live.connectAltView(id, to: .init(name: "Previous", host: "previous.local", port: 54321), code: "ABCD2345"))
        try await eventually { client.connectionID != nil }; client.welcome(); await settle(); service.disconnect()
        let preferred = AltViewDestination(name: "New choice", host: "preferred.local", port: 54321)
        var destination = live.outputs.destination(id)!, assignment = live.outputs.destination(id)!.altView!
        assignment.receiver = preferred; assignment.receiverID = nil; destination.assignment = .altView(assignment)
        XCTAssertNil(live.outputs.update(destination))
        service.selectTemplate(nil)
        XCTAssertEqual(live.outputs.destination(id)?.altView?.receiver, preferred, "Layout editing cannot restore a previous connected receiver")
        let manager = ManageOutputsController(live: live); manager.discoveryEnabled = false; _ = manager.view; manager.selectDestination(id)
        XCTAssertEqual(manager.remoteEditor?.hostField.stringValue, "preferred.local", "Reopening the editor uses the saved assignment")
        withExtendedLifetime(observation) {}
    }
    func testQuickControlsStaySeparateFromSharedProjectionCommandsAndSettings() {
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: selectedTestProjectionDisplays())
        defer { live.shutdown() }
        let workspace = MainWorkspaceController(liveProjection: live); _ = workspace.view; workspace.rebuildOptionMenus()
        let titles = workspace.projectionOptions.menu!.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, ["Project selected passage", "Blank", "Stop", "Manage Outputs…"])
        XCTAssertTrue(workspace.projectionOptions.menu!.items.allSatisfy { $0.submenu == nil })
        XCTAssertEqual(workspace.outputOptions.title, "Output")
        XCTAssertNotNil(workspace.outputOptions.menu?.items.first { $0.title == "Text alignment" }?.submenu)
        let outputMenu = workspace.outputOptions.menu
        workspace.rebuildOptionMenus()
        XCTAssertTrue(workspace.outputOptions.menu === outputMenu, "Routine refreshes must preserve the attached quick-control menu")
        let settings = NativeSettingsController(library: live.library, liveProjection: live)
        XCTAssertEqual(settings.tabViewItems.map(\.label), ["Manage Outputs", "Bible Library"])
        workspace.shutdown()
    }

    func testDefaultOutputMigrationSelectionDisableRemovalAndRecoveryRoundTrip() throws {
        let saved = defaults(), displays = ProjectionDisplayManager(displays: { [] })
        let store = OutputConfigurationStore(defaults: saved, displays: displays)
        let audience = store.destinations[0].id, other = store.addNative()
        XCTAssertEqual(store.defaultDestination?.id, audience)
        // A pre-default-output versioned document selects its first native output.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: saved.data(forKey: AppDefaultsKey.outputConfiguration)!) as? [String: Any])
        legacy.removeValue(forKey: "defaultDestinationID")
        saved.set(try JSONSerialization.data(withJSONObject: legacy), forKey: AppDefaultsKey.outputConfiguration)
        let migrated = OutputConfigurationStore(defaults: saved, displays: displays)
        XCTAssertEqual(migrated.defaultDestination?.id, audience)
        migrated.setDefaultDestination(other)
        XCTAssertEqual(migrated.defaultDestination?.enabled, false, "Choosing a default cannot enable it")
        let restored = OutputConfigurationStore(defaults: saved, displays: displays)
        XCTAssertEqual(restored.defaultDestination?.id, other)
        restored.remove(other)
        XCTAssertNil(OutputConfigurationStore(defaults: saved, displays: displays).defaultDestination, "Removal must not silently retarget controls")
        restored.setDefaultDestination(audience); restored.setDefaultDestination(nil)
        XCTAssertNil(OutputConfigurationStore(defaults: saved, displays: displays).defaultDestination)
        restored.setDefaultDestination(UUID()); XCTAssertNil(restored.defaultDestination)
        saved.set(Data("{}".utf8), forKey: AppDefaultsKey.outputConfiguration)
        let recovery = OutputConfigurationStore(defaults: saved, displays: displays)
        let configuration = recovery.configuration
        recovery.setDefaultDestination(configuration.destinations[0].id)
        XCTAssertEqual(recovery.configuration, configuration)
        XCTAssertNotNil(recovery.editDefaultProfile(destinationID: configuration.destinations[0].id) { $0.transparent.toggle() })
        XCTAssertEqual(saved.data(forKey: AppDefaultsKey.outputConfiguration), Data("{}".utf8))
    }

    func testQuickAppearanceEditsDetachAndReuseOnlyTheDefaultOutputsProfile() throws {
        let saved = defaults(), displays = ProjectionDisplayManager(displays: { [] })
        let store = OutputConfigurationStore(defaults: saved, displays: displays)
        let audience = store.destinations[0].id, other = store.addNative()
        let original = try XCTUnwrap(store.profile(NativeOutputProfile.audienceID)), before = store.configuration
        XCTAssertNil(store.editDefaultProfile(destinationID: audience) { $0.verse.size = original.verse.size })
        XCTAssertEqual(store.configuration, before, "A no-op must not create a private copy")
        XCTAssertNil(store.editDefaultProfile(destinationID: audience) { $0.verse.size = 48; $0.transparent = true })
        let copyID = try XCTUnwrap(store.destination(audience)?.native?.profileID)
        XCTAssertNotEqual(copyID, original.id)
        XCTAssertEqual(store.profile(original.id), original, "Quick edits preserve the reusable profile")
        XCTAssertEqual(store.destination(other)?.native?.profileID, original.id, "Even disabled outputs keep their appearance")
        XCTAssertEqual(store.profile(copyID)?.verse.size, 48)
        XCTAssertNil(store.editDefaultProfile(destinationID: audience) { $0.padding = 16 })
        XCTAssertEqual(store.destination(audience)?.native?.profileID, copyID)
        XCTAssertEqual(store.profiles.count, before.profiles.count + 1)
        let restored = OutputConfigurationStore(defaults: saved, displays: displays)
        XCTAssertNil(restored.editDefaultProfile(destinationID: audience) { $0.alignment = .left })
        XCTAssertEqual(restored.destination(audience)?.native?.profileID, copyID, "Private copy survives relaunch")
        assign(restored, other, to: nil, profile: copyID, enabled: false)
        let shared = restored.profile(copyID)
        XCTAssertNil(restored.editDefaultProfile(destinationID: audience) { $0.padding = 24 })
        XCTAssertNotEqual(restored.destination(audience)?.native?.profileID, copyID)
        XCTAssertEqual(restored.profile(copyID), shared, "Reusing a customized profile elsewhere makes the next quick edit independent again")
        let unchanged = restored.configuration
        XCTAssertNotNil(restored.editDefaultProfile(destinationID: audience) { $0.verse.size = .nan })
        XCTAssertEqual(restored.configuration, unchanged, "Invalid edits must be atomic")
    }

    func testDefaultOutputMenusIgnoreDisabledRemovedAndRetargetedActions() throws {
        _ = NSApplication.shared
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [self.monitor(1)] }))
        defer { live.shutdown() }
        live.nativeWindowFactory = { _, _, _ in nil }
        let workspace = MainWorkspaceController(liveProjection: live); _ = workspace.view
        defer { workspace.shutdown() }
        let audience = live.outputs.destinations[0].id, other = live.outputs.addNative()
        let menu = try XCTUnwrap(workspace.outputOptions.menu)
        let stale = try XCTUnwrap(menu.items.first { $0.title == "Transparent background" })
        let manager = ManageOutputsController(live: live); _ = manager.view; manager.selectDestination(other)
        manager.defaultButton.performClick(nil)
        XCTAssertEqual(live.outputs.defaultDestination?.id, other)
        XCTAssertEqual(live.outputs.defaultDestination?.enabled, false)
        workspace.rebuildOptionMenus()
        let disabled = try XCTUnwrap(workspace.outputOptions.menu)
        XCTAssertTrue(disabled.items.contains { $0.title == "Default output is disabled." })
        for title in ["Text alignment", "Projection monitor", "Reading direction", "Transparent background", "Verse size"] {
            XCTAssertEqual(disabled.items.first { $0.title == title }?.isEnabled, false)
        }
        XCTAssertEqual(disabled.items.first { $0.title == "Manage Outputs…" }?.isEnabled, true)
        let unchanged = live.outputs.configuration
        NSApp.sendAction(stale.action!, to: stale.target, from: stale)
        XCTAssertEqual(live.outputs.configuration, unchanged, "An old menu cannot edit its former default or the new selection")
        XCTAssertNotNil(live.outputs.editDefaultProfile(destinationID: other) { $0.transparent.toggle() })
        manager.selectDestination(audience); live.outputs.setDefaultDestination(audience); manager.reload()
        XCTAssertEqual(manager.defaultButton.title, "Default"); XCTAssertFalse(manager.defaultButton.isEnabled)
        manager.defaultButton.performClick(nil)
        XCTAssertEqual(live.outputs.defaultDestination?.id, audience, "The Default action must never toggle the current default off")
        live.outputs.setDefaultDestination(other)
        manager.selectDestination(audience); manager.defaultButton.performClick(nil)
        workspace.rebuildOptionMenus()
        let active = try XCTUnwrap(workspace.outputOptions.menu?.items.first { $0.title == "Transparent background" })
        NSApp.sendAction(active.action!, to: active.target, from: active)
        XCTAssertEqual(live.outputs.destination(audience)?.native.flatMap { live.outputs.profile($0.profileID)?.transparent }, true)
        XCTAssertEqual(live.outputs.destination(other)?.native.flatMap { live.outputs.profile($0.profileID)?.transparent }, false)
        live.outputs.remove(audience)
        let afterRemoval = live.outputs.configuration
        NSApp.sendAction(active.action!, to: active.target, from: active)
        XCTAssertEqual(live.outputs.configuration, afterRemoval)
        workspace.rebuildOptionMenus()
        XCTAssertEqual(workspace.outputOptions.title, "Output")
        XCTAssertNotNil(workspace.outputOptions.menu?.items.first { $0.title == "Default output: None" })
        XCTAssertTrue(live.nativeOutputs.isEmpty); XCTAssertNil(live.projector.projectionOwner)
    }

    func testDisabledDefaultDoesNotRestrictProjectBlankStopOrPublishDuringQuickEdits() async throws {
        _ = NSApplication.shared
        let sender = OutputSender()
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [self.monitor(1), self.monitor(2)] }),
            altViewServiceFactory: { saved, discovery in
                AltViewProjectionService(destination: saved.receiver, store: OutputPairings(), discovery: discovery) { sender.callback = $0; return sender }
            })
        defer { live.shutdown() }
        live.nativeWindowFactory = { _, _, _ in nil }
        let audience = live.outputs.destinations[0].id, other = live.outputs.addNative(), disabled = live.outputs.addNative(), remote = live.outputs.addAltView()
        assign(live.outputs, audience, to: monitor(1), profile: NativeOutputProfile.audienceID)
        assign(live.outputs, other, to: monitor(2), profile: NativeOutputProfile.audienceID)
        live.outputs.setDefaultDestination(disabled)
        XCTAssertNil(live.connectAltView(remote, to: .init(name: "Receiver", host: "receiver.local", port: 54321), code: "ABCD2345"))
        try await eventually { sender.connectionID != nil }; sender.welcome(); await settle()
        let workspace = MainWorkspaceController(liveProjection: live); _ = workspace.view
        defer { workspace.shutdown() }
        live.publishRow(projection(), from: workspace.tabID)
        XCTAssertEqual(Set(live.nativeOutputs.keys), Set([audience, other]))
        XCTAssertNotNil(sender.submissions.last?.content)
        workspace.rebuildOptionMenus()
        let blank = try XCTUnwrap(workspace.projectionOptions.menu?.items.first { $0.title == "Blank" })
        let outputMenu = workspace.outputOptions.menu
        XCTAssertTrue(blank.isEnabled); NSApp.sendAction(blank.action!, to: blank.target, from: blank)
        workspace.rebuildOptionMenus()
        XCTAssertTrue(workspace.outputOptions.menu === outputMenu, "Blanking and routine feedback must not replace quick controls")
        XCTAssertTrue(live.projector.isBlanked); XCTAssertEqual(sender.submissions.last?.content?.visible, false)
        let revision = live.projector.revision, source = live.source, submissions = sender.submissions.count
        live.outputs.setDefaultDestination(audience); workspace.rebuildOptionMenus()
        let align = try XCTUnwrap(workspace.outputOptions.menu?.items.first { $0.title == "Text alignment" }?.submenu?.items.first { $0.title == "Left" })
        NSApp.sendAction(align.action!, to: align.target, from: align)
        XCTAssertEqual(live.nativeOutputs[audience]?.appearance.profile.alignment, .left)
        XCTAssertEqual(live.nativeOutputs[other]?.appearance.profile.alignment, .center)
        XCTAssertTrue(live.projector.isBlanked); XCTAssertEqual(live.projector.revision, revision); XCTAssertEqual(live.source, source)
        XCTAssertEqual(sender.submissions.count, submissions, "Appearance/default selection cannot publish or take remote output")
        live.outputs.setDefaultDestination(disabled); workspace.rebuildOptionMenus()
        let stop = try XCTUnwrap(workspace.projectionOptions.menu?.items.first { $0.title == "Stop" })
        XCTAssertTrue(stop.isEnabled); NSApp.sendAction(stop.action!, to: stop.target, from: stop)
        await settle()
        XCTAssertTrue(live.nativeOutputs.isEmpty); XCTAssertNil(sender.submissions.last?.content); XCTAssertNil(live.projector.projectionOwner)
    }

    func testQuickMonitorSelectionKeepsConflictAndActiveWindowGuards() throws {
        _ = NSApplication.shared
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [self.monitor(1), self.monitor(2), self.monitor(3)] }))
        defer { live.shutdown() }
        live.nativeWindowFactory = { _, _, _ in nil }
        let audience = live.outputs.destinations[0].id, other = live.outputs.addNative()
        assign(live.outputs, audience, to: monitor(1), profile: NativeOutputProfile.audienceID)
        assign(live.outputs, other, to: monitor(2), profile: NativeOutputProfile.audienceID)
        let workspace = MainWorkspaceController(liveProjection: live); _ = workspace.view
        defer { workspace.shutdown() }
        let menu = try XCTUnwrap(workspace.outputOptions.menu?.items.first { $0.title == "Projection monitor" }?.submenu)
        let occupied = live.projectionDisplays.label(for: monitor(2).target), available = live.projectionDisplays.label(for: monitor(3).target)
        XCTAssertEqual(menu.items.first { $0.title == occupied }?.isEnabled, false)
        let stale = try XCTUnwrap(menu.items.first { $0.title == available })
        XCTAssertTrue(stale.isEnabled)
        live.publishRow(projection(), from: UUID())
        workspace.rebuildOptionMenus()
        XCTAssertEqual(workspace.outputOptions.menu?.items.first { $0.title == "Projection monitor" }?.isEnabled, false)
        NSApp.sendAction(stale.action!, to: stale.target, from: stale)
        XCTAssertEqual(live.outputs.destination(audience)?.native?.monitor, monitor(1).target)
        live.closeProjector()
        NSApp.sendAction(stale.action!, to: stale.target, from: stale)
        XCTAssertEqual(live.outputs.destination(audience)?.native?.monitor, monitor(3).target)
        XCTAssertEqual(live.outputs.destination(other)?.native?.monitor, monitor(2).target)
        XCTAssertTrue(live.nativeOutputs.isEmpty, "Changing a non-clock monitor assignment cannot open output")
    }

    func testAltViewDefaultQuickLayoutEditsOnlyItsSavedChoiceUntilExplicitProjection() async throws {
        _ = NSApplication.shared
        let first = OutputSender(), second = OutputSender()
        var clients = [first, second]
        let live = LiveProjectionController(defaults: defaults(), projectionDisplays: ProjectionDisplayManager(displays: { [] }),
            altViewServiceFactory: { saved, discovery in
                let sender = clients.removeFirst()
                return AltViewProjectionService(destination: saved.receiver, template: saved.template, store: OutputPairings(), discovery: discovery) { sender.callback = $0; return sender }
            })
        defer { live.shutdown() }
        let one = live.outputs.addAltView(), two = live.outputs.addAltView()
        for (id, host) in [(one, "one.local"), (two, "two.local")] {
            XCTAssertNil(live.connectAltView(id, to: .init(name: host, host: host, port: 54321), code: "ABCD2345"))
        }
        try await eventually { first.connectionID != nil && second.connectionID != nil }
        for sender in [first, second] {
            sender.callback?(.init(connectionID: sender.connectionID, connected: true, receiverID: sender.receiverID,
                templateCapabilities: .init(templates: [.init(id: .scripture, name: "Scripture"), .init(id: .lyrics, name: "Lyrics")], policy: .sender)))
        }
        await settle()
        live.outputs.setDefaultDestination(one)
        let workspace = MainWorkspaceController(liveProjection: live); _ = workspace.view
        defer { workspace.shutdown() }
        let layouts = try XCTUnwrap(workspace.outputOptions.menu?.items.first { $0.title == "Layout" })
        XCTAssertTrue(layouts.isEnabled)
        let lyrics = try XCTUnwrap(layouts.submenu?.items.first { $0.title == "Lyrics" })
        NSApp.sendAction(lyrics.action!, to: lyrics.target, from: lyrics)
        XCTAssertEqual(live.outputs.destination(one)?.altView?.template, .lyrics)
        XCTAssertEqual(live.outputs.destination(two)?.altView?.template, .scripture)
        XCTAssertTrue(first.submissions.isEmpty && second.submissions.isEmpty)
        live.publishRow(projection(), from: UUID())
        XCTAssertEqual(first.submissions.last?.content?.template, .lyrics)
        XCTAssertEqual(second.submissions.last?.content?.template, .scripture)
        var disabled = live.outputs.destination(one)!; disabled.enabled = false
        XCTAssertNil(live.outputs.update(disabled)); live.refreshPreferences(); workspace.rebuildOptionMenus()
        XCTAssertEqual(workspace.outputOptions.menu?.items.first { $0.title == "Layout" }?.isEnabled, false)
        XCTAssertTrue(workspace.outputOptions.menu!.items.contains { $0.title == "Default output is disabled." })
        NSApp.sendAction(lyrics.action!, to: lyrics.target, from: lyrics)
        XCTAssertEqual(live.outputs.destination(one)?.altView?.template, .lyrics)
    }
}
