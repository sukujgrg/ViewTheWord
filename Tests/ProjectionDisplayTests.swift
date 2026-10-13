import AppKit
import XCTest
@testable import ViewTheWordCore

@MainActor
final class ProjectionDisplayTests: XCTestCase {
    private let leftID = "11111111-1111-1111-1111-111111111111"
    private let rightID = "22222222-2222-2222-2222-222222222222"
    private let thirdID = "33333333-3333-3333-3333-333333333333"
    private func monitor(_ id: UInt32, _ identity: String?, mirrored: Bool = false) -> ProjectionMonitor {
        ProjectionMonitor(id: id, identity: identity, name: "Same TV", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMirrored: mirrored)
    }
    func testIdenticalNamesKeepNumbersAndNamesAcrossReorderNewIDsAndRelaunch() {
        let suite = "MonitorLabels.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID), monitor(12, thirdID)])
        let manager = ProjectionDisplayManager(defaults: defaults, displays: { inventory.displays })
        let targets = inventory.displays.map(\.target)
        XCTAssertEqual(targets.map { manager.number(for: $0) }, [1, 2, 3], suite)
        for (target, name) in zip(targets, ["Front Left TV", "Front Right TV", "Lobby TV"]) { XCTAssertTrue(manager.rename(target, to: name)) }
        inventory.displays = [monitor(90, thirdID), monitor(92, leftID), monitor(91, rightID)]; manager.refresh()
        let restored = ProjectionDisplayManager(defaults: defaults, displays: { inventory.displays })
        XCTAssertEqual(restored.displays.map(\.identity), [leftID, rightID, thirdID])
        XCTAssertEqual(targets.map { restored.label(for: $0) }, ["1 · Front Left TV", "2 · Front Right TV", "3 · Lobby TV"])
        XCTAssertEqual(restored.resolve(targets[1])?.id, 91)
    }
    func testMissingMonitorNeverResolvesReusedRuntimeIDOrSameModelName() {
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays }); let target = inventory.displays[0].target
        inventory.displays = [monitor(10, rightID)]; manager.refresh()
        XCTAssertNil(manager.resolve(target)); XCTAssertTrue(manager.problem(for: target)?.contains("disconnected") == true)
        inventory.displays.append(monitor(99, leftID)); manager.refresh(); XCTAssertEqual(manager.resolve(target)?.id, 99)
    }
    func testNumbersAreNeverReusedForNewMonitorsAfterDisconnection() {
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        inventory.displays = [monitor(20, thirdID)]; manager.refresh()
        XCTAssertEqual(manager.number(for: inventory.displays[0].target), 3); XCTAssertEqual(manager.knownTargets.count, 3)
    }
    func testAmbiguousMirroredUnknownAndZeroSizedMonitorsCannotProject() {
        let zero = ProjectionMonitor(id: 14, identity: thirdID, name: "TV", frame: .zero)
        let inventory = [monitor(10, leftID), monitor(11, leftID), monitor(12, rightID, mirrored: true), monitor(13, nil), zero]
        let manager = ProjectionDisplayManager(displays: { inventory })
        for display in inventory {
            XCTAssertNotNil(manager.problem(for: display.target)); XCTAssertNil(manager.resolve(display.target)); XCTAssertFalse(manager.canIdentify(display.target))
        }
        XCTAssertFalse(manager.canRename(inventory[0].target)); XCTAssertFalse(manager.canRename(inventory[3].target))
    }
    func testIdentificationLocksOnlyActiveMonitorsAndNamesSurviveDisconnect() {
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays }); let targets = inventory.displays.map(\.target)
        let owner = UUID(); manager.lock(targets[0], owner: owner)
        XCTAssertFalse(manager.canIdentify(targets[0])); XCTAssertTrue(manager.canIdentify(targets[1]))
        XCTAssertTrue(manager.rename(targets[0], to: "Live Projector"))
        inventory.displays = []; manager.refresh()
        XCTAssertEqual(manager.label(for: targets[0]), "1 · Live Projector"); XCTAssertFalse(manager.canIdentify(targets[0]))
        manager.unlock(owner: owner); XCTAssertFalse(manager.isLocked)
    }
    func testNamesRejectControlCharactersAndLongInput() {
        let monitor = monitor(10, leftID), manager = ProjectionDisplayManager(displays: { [] })
        XCTAssertNil(ProjectionDisplayManager.normalizedName("Line\nBreak"))
        XCTAssertNil(ProjectionDisplayManager.normalizedName(String(repeating: "x", count: 41)))
        XCTAssertEqual(ProjectionDisplayManager.normalizedName(" Front TV "), "Front TV")
        XCTAssertFalse(manager.rename(monitor.target, to: "TV"))
    }
    func testScreenContentCoordinatesUseFullFrameIncludingNonzeroOrigins() {
        let frame = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        XCTAssertEqual(ProjectionScreenResolver.screenRelativeContentRect(for: frame), CGRect(origin: .zero, size: frame.size))
    }
}

@MainActor
private final class MonitorInventory {
    var displays: [ProjectionMonitor]
    init(_ displays: [ProjectionMonitor]) { self.displays = displays }
}

/// Explicit legacy assignment feeds migration in isolated passage fixtures.
@MainActor
func selectedTestProjectionDisplays() -> ProjectionDisplayManager {
    let display = ProjectionMonitor(id: 10, identity: "11111111-1111-1111-1111-111111111111", name: "Fixture Monitor", frame: CGRect(x: -10000, y: -10000, width: 640, height: 360))
    let suite = "SelectedMonitor.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(try! JSONEncoder().encode(display.target), forKey: AppDefaultsKey.projectionMonitorAssignment)
    let manager = ProjectionDisplayManager(defaults: defaults, displays: { [display] })
    defaults.removePersistentDomain(forName: suite)
    return manager
}

@MainActor
@discardableResult
func assignTestNativeOutput(_ live: LiveProjectionController, to target: ProjectionMonitorTarget?) -> String? {
    var destination = live.outputs.destinations.first { $0.native != nil }!
    var assignment = destination.native!; assignment.monitor = target; destination.assignment = .native(assignment)
    return live.outputs.update(destination)
}
