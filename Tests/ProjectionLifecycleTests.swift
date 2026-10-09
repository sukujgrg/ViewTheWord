import AppKit
import XCTest
@testable import ViewTheWordCore

private final class ProjectionActivityRecorder {
    var begun: [NSObject] = []
    var ended: [ObjectIdentifier] = []
    var options: [ProcessInfo.ActivityOptions] = []
    func protection() -> ProjectionSleepPrevention {
        ProjectionSleepPrevention(beginActivity: { [self] options, reason in
            XCTAssertEqual(reason, "Presenting ViewTheWord output")
            self.options.append(options)
            let token = NSObject()
            begun.append(token)
            return token
        }, endActivity: { [self] in ended.append(ObjectIdentifier($0)) })
    }
    var balanced: Bool { ended == begun.map(ObjectIdentifier.init) }
}

@MainActor
private final class WeakProjectionOwner {
    weak var value: LiveProjectionController?
    init(_ value: LiveProjectionController?) { self.value = value }
}

@MainActor
private final class ProjectionInventory {
    var monitors: [ProjectionMonitor]
    init(_ monitors: [ProjectionMonitor]) { self.monitors = monitors }
}

@MainActor
private final class RecordedProjectionWindow: NSWindow {
    var frontCount = 0
    override func orderFrontRegardless() { frontCount += 1 }
}

@MainActor
final class ProjectionLifecycleTests: XCTestCase {
    private let identity = "11111111-1111-1111-1111-111111111111"
    private let otherIdentity = "22222222-2222-2222-2222-222222222222"
    private func monitor(_ id: UInt32 = 10, identity: String? = nil) -> ProjectionMonitor {
        ProjectionMonitor(id: id, identity: identity ?? self.identity, name: "Same TV",
                          frame: CGRect(x: -10000, y: -10000, width: 640, height: 360))
    }
    private func projection() -> PreparedProjection {
        let reference = VerseReference(book: "John", chapter: 3, verse: 16)!
        return PreparedProjection(pair: TranslationPair(reference: reference,
            primary: AVerse(reference: reference, verse: "Test projection"), secondary: nil),
            sources: BibleSources(primary: URL(fileURLWithPath: "/tmp/ENG_TEST.bible"), secondary: nil, revision: 1),
            owner: .verseRowSelection(reference))!
    }
    private func live(_ displays: ProjectionDisplayManager, recorder: ProjectionActivityRecorder) -> LiveProjectionController {
        let prepared = projection()
        let defaults = UserDefaults(suiteName: "ProjectionLifecycleTests.\(UUID())")!
        let live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [prepared.sources.primary]), defaults: defaults,
                                            projectionDisplays: displays, sleepPrevention: recorder.protection())
        live.projectorWindowFactory = { _ in
            let window = RecordedProjectionWindow(contentRect: CGRect(x: -10000, y: -10000, width: 640, height: 360),
                                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        return live
    }
    private func settleClose() async { for _ in 0..<4 { await Task.yield() } }

    func testOneActivitySurvivesBlankTransparencyRefreshAndExplicitFrontOrdering() async throws {
        _ = NSApplication.shared
        let recorder = ProjectionActivityRecorder()
        let displays = selectedTestProjectionDisplays()
        let live = live(displays, recorder: recorder)
        defer { live.shutdown() }
        let tab = UUID()
        live.publishRow(projection(), from: tab)
        let window = try XCTUnwrap(live.ownedProjectorWindow as? RecordedProjectionWindow)
        XCTAssertEqual(window.frontCount, 1)
        XCTAssertEqual(recorder.begun.count, 1)
        XCTAssertTrue(displays.isLocked)
        XCTAssertFalse(displays.canIdentify(try XCTUnwrap(displays.target)))
        live.toggleBlank()
        live.defaults.set(true, forKey: AppDefaultsKey.transparentBackground)
        live.refreshPreferences()
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        let prepared = projection()
        let token = live.beginIntent(from: tab, sources: prepared.sources, using: VerseTargetModel())
        live.publish(prepared, intent: token, preserveBlanking: true)
        XCTAssertTrue(live.projector.isBlanked)
        XCTAssertEqual(window.frontCount, 1, "Background refresh leaves underlying presentations in their current order")
        XCTAssertEqual(recorder.begun.count, 1)
        XCTAssertTrue(recorder.ended.isEmpty)
        live.publishRow(prepared, from: tab)
        XCTAssertEqual(window.frontCount, 2, "Even an already-open output must rise on explicit projection")
        XCTAssertFalse(live.projector.isBlanked)
        live.closeProjector()
        XCTAssertTrue(recorder.balanced, "Native close releases immediately, before deferred payload cleanup")
        await settleClose()
        XCTAssertFalse(live.windowOpened)
        XCTAssertFalse(displays.isLocked)
        live.publishRow(prepared, from: tab)
        XCTAssertEqual(recorder.begun.count, 2)
        live.shutdown()
        XCTAssertTrue(recorder.balanced)
        for options in recorder.options {
            XCTAssertTrue(options.contains([.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled]))
        }
    }

    func testDisconnectMirroringAmbiguityAndReconnectionNeverFallBackOrRestart() async throws {
        _ = NSApplication.shared
        let original = monitor()
        let other = monitor(11, identity: otherIdentity)
        let inventory = ProjectionInventory([original, other])
        let displays = ProjectionDisplayManager(displays: { inventory.monitors })
        XCTAssertTrue(displays.select(original.target))
        let recorder = ProjectionActivityRecorder()
        let live = live(displays, recorder: recorder)
        defer { live.shutdown() }
        var mirrored = original
        mirrored.isMirrored = true
        let duplicate = monitor(12)
        for unavailable in [[other], [mirrored, other], [original, duplicate, other]] {
            live.publishRow(projection(), from: UUID())
            let oldWindow = try XCTUnwrap(live.ownedProjectorWindow)
            let oldFrame = oldWindow.frame
            inventory.monitors = unavailable
            displays.refresh()
            XCTAssertTrue(recorder.balanced)
            XCTAssertEqual(oldWindow.frame, oldFrame, "No fallback screen movement")
            XCTAssertEqual(displays.target, original.target)
            await settleClose()
            XCTAssertFalse(live.windowOpened)
            XCTAssertNotNil(live.message)
            live.publishRow(projection(), from: UUID())
            XCTAssertFalse(live.windowOpened, "An unavailable assignment blocks all explicit publication")
            XCTAssertNil(live.projector.projectionOwner)
            let starts = recorder.begun.count
            inventory.monitors = [monitor(99), other]
            displays.refresh()
            live.refreshPreferences()
            await settleClose()
            XCTAssertFalse(live.windowOpened)
            XCTAssertEqual(recorder.begun.count, starts)
            XCTAssertEqual(displays.resolvedMonitor()?.id, 99)
        }
        XCTAssertEqual(recorder.begun.count, 3)
        live.publishRow(projection(), from: UUID())
        XCTAssertTrue(live.windowOpened, "Reconnection permits a new explicit projection")
    }

    func testGeometryChangesOnlyRepositionSameUUIDAndDoNotBringToFront() async throws {
        _ = NSApplication.shared
        let inventory = ProjectionInventory([monitor(), monitor(11, identity: otherIdentity)])
        let displays = ProjectionDisplayManager(displays: { inventory.monitors })
        displays.select(inventory.monitors[0].target)
        let recorder = ProjectionActivityRecorder()
        let live = live(displays, recorder: recorder)
        defer { live.shutdown() }
        live.publishRow(projection(), from: UUID())
        let window = try XCTUnwrap(live.ownedProjectorWindow as? RecordedProjectionWindow)
        let moved = ProjectionMonitor(id: 99, identity: identity, name: "Renamed model",
                                      frame: CGRect(x: -12000, y: -11000, width: 800, height: 600))
        inventory.monitors = [monitor(10, identity: otherIdentity), moved]
        displays.refresh()
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(window.frame, moved.frame)
        XCTAssertEqual(window.frontCount, 1)
        XCTAssertFalse(displays.select(inventory.monitors[0].target))
        XCTAssertEqual(displays.target?.identity, identity)
        XCTAssertEqual(recorder.begun.count, 1)
    }

    func testUnassignedUnavailablePendingIdentifyAndSuppressedWindowsHaveNoActivity() async {
        let inventory = ProjectionInventory([monitor()])
        let displays = ProjectionDisplayManager(displays: { inventory.monitors })
        let recorder = ProjectionActivityRecorder()
        let live = live(displays, recorder: recorder)
        defer { live.shutdown() }
        let prepared = projection()
        let model = VerseTargetModel()
        _ = live.beginIntent(from: UUID(), sources: prepared.sources, using: model)
        XCTAssertTrue(recorder.begun.isEmpty)
        displays.identify(inventory.monitors[0].target)
        live.publishRow(prepared, from: UUID())
        XCTAssertFalse(live.windowOpened)
        XCTAssertNil(live.projector.projectionOwner)
        XCTAssertNotNil(live.message)
        XCTAssertTrue(displays.select(inventory.monitors[0].target))
        inventory.monitors = []
        live.publishRow(prepared, from: UUID()) // Rechecks before screen-change notification.
        XCTAssertFalse(live.windowOpened)
        inventory.monitors = [monitor()]
        live.projectorWindowFactory = { _ in nil }
        live.publishRow(prepared, from: UUID())
        XCTAssertTrue(live.windowOpened, "Fixture live state can be tested without a physical output")
        XCTAssertTrue(recorder.begun.isEmpty)
        live.closeProjector()
        await settleClose()
        XCTAssertTrue(recorder.balanced)
    }

    func testOwnerTeardownEndsActivityClosesWindowAndUnlocksMonitor() async throws {
        _ = NSApplication.shared
        let recorder = ProjectionActivityRecorder()
        let displays = selectedTestProjectionDisplays()
        var live: LiveProjectionController? = live(displays, recorder: recorder)
        live?.publishRow(projection(), from: UUID())
        let window = try XCTUnwrap(live?.ownedProjectorWindow)
        let owner = WeakProjectionOwner(live)
        live = nil
        XCTAssertNil(owner.value)
        XCTAssertTrue(recorder.balanced)
        await settleClose()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(displays.isLocked)
    }

    func testMonitorLossCancelsPendingPublicationAndReconnectCannotAcceptItsOldToken() async {
        _ = NSApplication.shared
        let inventory = ProjectionInventory([monitor()])
        let displays = ProjectionDisplayManager(displays: { inventory.monitors })
        displays.select(inventory.monitors[0].target)
        let recorder = ProjectionActivityRecorder()
        let live = live(displays, recorder: recorder)
        defer { live.shutdown() }
        let prepared = projection()
        live.publishRow(prepared, from: UUID())
        let token = live.beginIntent(from: UUID(), sources: prepared.sources, using: VerseTargetModel())
        inventory.monitors = []
        displays.refresh()
        inventory.monitors = [monitor(99)]
        displays.refresh()
        live.publish(prepared, intent: token)
        await settleClose()
        XCTAssertFalse(live.windowOpened)
        XCTAssertFalse(live.isProjecting)
        XCTAssertNil(live.projector.projectionOwner)
        XCTAssertEqual(recorder.begun.count, 1)
        XCTAssertTrue(recorder.balanced)
    }

    func testSleepHelperIsIdempotentAndBalancesRetainedTokenOnTeardown() {
        let recorder = ProjectionActivityRecorder()
        var protection: ProjectionSleepPrevention? = recorder.protection()
        protection?.stop()
        protection?.start()
        protection?.start()
        XCTAssertEqual(recorder.begun.count, 1)
        protection?.stop()
        protection?.stop()
        XCTAssertTrue(recorder.balanced)
        protection?.start()
        protection = nil
        XCTAssertEqual(recorder.begun.count, 2)
        XCTAssertTrue(recorder.balanced)
    }

    func testNativeSettingsUsesSharedAuthorityAndDetailsButtonSpansEntireRow() {
        let displays = selectedTestProjectionDisplays()
        let settings = NativeSettingsController(library: BibleLibrary(preloadedURLs: []), defaults: .standard, projectionDisplays: displays)
        XCTAssertTrue(settings.monitors.displays === displays)
        let editor = ProjectionMonitorNameController(displays: displays, target: displays.target!)
        editor.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.details.isHidden)
        XCTAssertEqual(editor.disclosure.frame.width, 392, accuracy: 1)
        editor.disclosure.performClick(nil)
        XCTAssertFalse(editor.details.isHidden)
        editor.disclosure.performClick(nil)
        XCTAssertTrue(editor.details.isHidden)
        _ = settings.monitors.view
        settings.monitors.reload()
        XCTAssertTrue(settings.monitors.picker.isEnabled)
        let owner = UUID()
        displays.lock(displays.target!, owner: owner)
        settings.monitors.reload()
        XCTAssertFalse(settings.monitors.picker.isEnabled)
        displays.unlock(owner: owner)
    }
}
