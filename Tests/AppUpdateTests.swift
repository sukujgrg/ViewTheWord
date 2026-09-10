import AppKit
import XCTest
@testable import ViewTheWordCore

@MainActor
private final class UpdateDriverFixture: AppUpdateDriving {
    var state = AppUpdateState() { didSet { onStateChange?(state) } }
    var onStateChange: ((AppUpdateState) -> Void)?
    var starts = 0
    var checks = 0
    func start() { starts += 1; state.canCheckForUpdates = true }
    func checkForUpdates() { checks += 1; state.canCheckForUpdates = false }
    func setAutomaticChecks(_ enabled: Bool) { state.automaticallyChecksForUpdates = enabled }
}

@MainActor
final class AppUpdateTests: XCTestCase {
    func testOneUpdaterStartAndMenuTracksAvailabilityAndPreference() {
        let driver = UpdateDriverFixture()
        let updater = AppUpdateController(driver: driver)
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(updater.checkForUpdates(_:)), keyEquivalent: "")
        let automatic = NSMenuItem(title: "Automatically Check for Updates", action: #selector(updater.toggleAutomaticChecks(_:)), keyEquivalent: "")
        XCTAssertFalse(updater.validateMenuItem(check))
        updater.checkForUpdates(nil)
        XCTAssertEqual(driver.checks, 0)
        updater.start()
        updater.start()
        XCTAssertEqual(driver.starts, 1)
        XCTAssertTrue(updater.validateMenuItem(check))
        updater.checkForUpdates(nil)
        updater.checkForUpdates(nil)
        XCTAssertEqual(driver.checks, 1)
        XCTAssertFalse(updater.validateMenuItem(check))
        XCTAssertTrue(updater.validateMenuItem(automatic))
        XCTAssertEqual(automatic.state, .on)
        updater.toggleAutomaticChecks(nil)
        XCTAssertTrue(updater.validateMenuItem(automatic))
        XCTAssertEqual(automatic.state, .off)
        XCTAssertFalse(driver.state.automaticallyChecksForUpdates)
    }

    func testSharedUpdateReminderPreservesFocusAndLiveProjectionAcrossWindows() async throws {
        _ = NSApplication.shared
        let driver = UpdateDriverFixture()
        let updater = AppUpdateController(driver: driver)
        updater.start()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "AppUpdateTests.\(UUID())")!
        let sources = BibleSources(primary: directory.appendingPathComponent("ENG_TST.bible"), secondary: nil, revision: 1)
        let live = LiveProjectionController(library: BibleLibrary(preloadedURLs: [sources.primary]), defaults: defaults,
                                            sourceResolver: { _ in sources })
        let reference = VerseReference(book: "John", chapter: 3, verse: 16)!
        live.projector.project(.empty, owner: .textInputTarget(reference))
        let windows = (0..<2).map { _ in
            let workspace = MainWorkspaceController(
                history: HistoryStore(fileURL: directory.appendingPathComponent("history.json")),
                bookmarks: BookmarkStore(fileURL: directory.appendingPathComponent("bookmarks.json")),
                liveProjection: live, updates: updater)
            let window = MainWindowController(workspace: workspace, savesFrame: false)
            window.window!.tabbingMode = .disallowed
            window.window!.setFrameOrigin(NSPoint(x: -10000, y: -10000))
            window.window!.orderBack(nil)
            return window
        }
        defer {
            windows.forEach { $0.close() }
            try? FileManager.default.removeItem(at: directory)
        }
        let first = windows[0]
        first.window?.makeKey()
        first.workspace.focusSearch(nil)
        let responder = first.window?.firstResponder
        var changeCount = 0
        let subscription = updater.objectWillChange.sink { changeCount += 1 }
        defer { subscription.cancel() }
        driver.state.availableVersion = "3.1.0"
        for _ in 0..<100 {
            if windows.allSatisfy({ $0.window!.toolbar!.items.contains { $0.itemIdentifier == .workspaceUpdate } }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(changeCount, 1)
        for window in windows {
            let item = try XCTUnwrap(window.window?.toolbar?.items.first { $0.itemIdentifier == .workspaceUpdate },
                "state=\(updater.state); mounted=\(window.workspace.view.window != nil); items=\(window.window?.toolbar?.items.map(\.itemIdentifier) ?? [])")
            let button = try XCTUnwrap(item.view as? NSButton)
            XCTAssertTrue(button.target === updater)
            XCTAssertTrue(button.isEnabled)
            XCTAssertTrue(button.toolTip?.contains("3.1.0") == true)
        }
        XCTAssertTrue(first.window?.firstResponder === responder)
        XCTAssertEqual(live.projector.projectionOwner, .textInputTarget(reference))
        first.close()
        driver.state.availableVersion = nil
        for _ in 0..<100 {
            if !windows[1].window!.toolbar!.items.contains(where: { $0.itemIdentifier == .workspaceUpdate }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(windows[1].window!.toolbar!.items.contains { $0.itemIdentifier == .workspaceUpdate })
        XCTAssertEqual(live.projector.projectionOwner, .textInputTarget(reference))
        XCTAssertEqual(driver.starts, 1)
    }
}
