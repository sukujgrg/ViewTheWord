import AppKit
import XCTest
@testable import ViewTheWordCore

@MainActor
final class ProjectionDisplayTests: XCTestCase {
    private let leftID = "11111111-1111-1111-1111-111111111111"
    private let rightID = "22222222-2222-2222-2222-222222222222"
    private let thirdID = "33333333-3333-3333-3333-333333333333"

    private func monitor(_ id: UInt32, _ identity: String?, builtIn: Bool = false, mirrored: Bool = false) -> ProjectionMonitor {
        ProjectionMonitor(id: id, identity: identity, name: "Same TV", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                          isBuiltIn: builtIn, isMirrored: mirrored)
    }

    private func defaults() throws -> (UserDefaults, String) {
        let name = "ViewTheWord.ProjectionDisplayTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testIdenticalNamesKeepNumbersAndNamesAcrossReorderNewIDsAndRelaunch() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID), monitor(12, thirdID)])
        let manager = ProjectionDisplayManager(defaults: defaults, displays: { inventory.displays })
        let targets = inventory.displays.map(\.target)
        XCTAssertEqual(targets.map { manager.number(for: $0) }, [1, 2, 3])
        XCTAssertTrue(manager.rename(targets[0], to: "Front Left TV"))
        XCTAssertTrue(manager.rename(targets[1], to: "Front Right TV"))
        XCTAssertTrue(manager.rename(targets[2], to: "Lobby TV"))
        XCTAssertTrue(manager.select(targets[1]))
        inventory.displays = [monitor(90, thirdID), monitor(92, leftID), monitor(91, rightID)]
        manager.refresh()
        let restored = ProjectionDisplayManager(defaults: defaults, displays: { inventory.displays })
        XCTAssertEqual(restored.displays.map(\.identity), [leftID, rightID, thirdID])
        XCTAssertEqual(targets.map { restored.label(for: $0) }, ["1 · Front Left TV", "2 · Front Right TV", "3 · Lobby TV"])
        XCTAssertEqual(restored.target, targets[1])
        XCTAssertEqual(restored.resolvedMonitor()?.id, 91)
    }

    func testMissingMonitorNeverResolvesReusedRuntimeIDOrSameModelName() {
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        let selected = inventory.displays[0].target
        XCTAssertTrue(manager.select(selected))
        inventory.displays = [monitor(10, rightID)]
        manager.refresh()
        XCTAssertEqual(manager.target, selected)
        XCTAssertNil(manager.resolvedMonitor())
        XCTAssertTrue(manager.selectionProblem?.contains("disconnected") == true)
        inventory.displays.append(monitor(99, leftID))
        manager.refresh()
        XCTAssertEqual(manager.resolvedMonitor()?.id, 99)
    }

    func testNumbersAreNeverReusedForNewMonitorsAfterDisconnection() {
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        inventory.displays = [monitor(20, thirdID)]
        manager.refresh()
        XCTAssertEqual(manager.number(for: inventory.displays[0].target), 3)
        XCTAssertEqual(manager.knownTargets.count, 3)
    }

    func testAmbiguousMirroredUnknownAndZeroSizedMonitorsCannotProject() {
        var zeroSized = monitor(14, thirdID)
        zeroSized = ProjectionMonitor(id: zeroSized.id, identity: zeroSized.identity, name: zeroSized.name, frame: .zero)
        let inventory = [monitor(10, leftID), monitor(11, leftID), monitor(12, rightID, mirrored: true),
                         monitor(13, nil), zeroSized]
        let manager = ProjectionDisplayManager(displays: { inventory })
        for display in inventory {
            XCTAssertNotNil(manager.problem(for: display.target))
            XCTAssertFalse(manager.select(display.target))
            XCTAssertFalse(manager.canIdentify(display.target))
        }
        XCTAssertFalse(manager.canRename(inventory[0].target))
        XCTAssertFalse(manager.canRename(inventory[3].target))
        XCTAssertNil(manager.resolvedMonitor())
    }

    func testUnassignedProjectionNeverChoosesAConnectedMonitorIncludingAfterInventoryChanges() {
        let inventory = MonitorInventory([monitor(1, thirdID, builtIn: true), monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        XCTAssertNil(manager.target)
        XCTAssertNil(manager.resolvedMonitor())
        XCTAssertEqual(manager.selectionLabel, "Choose a monitor")
        XCTAssertTrue(manager.selectionProblem?.contains("Choose a projection monitor") == true)
        inventory.displays.reverse()
        manager.refresh()
        XCTAssertNil(manager.target)
        XCTAssertNil(manager.resolvedMonitor())
        XCTAssertTrue(manager.select(inventory.displays[0].target))
        XCTAssertEqual(manager.resolvedMonitor()?.identity, rightID)
    }

    func testBuiltInMonitorRequiresExplicitSelectionEvenWhenItIsTheOnlyUsableMonitor() {
        let builtIn = monitor(1, rightID, builtIn: true)
        let manager = ProjectionDisplayManager(displays: {
            [self.monitor(10, self.leftID, mirrored: true), builtIn]
        })
        XCTAssertNil(manager.resolvedMonitor())
        XCTAssertTrue(manager.select(builtIn.target))
        XCTAssertEqual(manager.resolvedMonitor()?.identity, rightID)
    }

    func testLegacySelectionMigratesOnceToUUID() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(10, forKey: AppDefaultsKey.projectorScreenDisplayID)
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(defaults: defaults, displays: { inventory.displays })
        XCTAssertEqual(manager.target?.identity, leftID)
        inventory.displays = [monitor(10, rightID), monitor(99, leftID)]
        let restored = ProjectionDisplayManager(defaults: defaults, displays: { inventory.displays })
        XCTAssertEqual(restored.resolvedMonitor()?.id, 99)
    }

    func testPreviousAutoPreferencesRequireAnExplicitMonitorAndPersistTheChoice() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let inventory = [monitor(10, leftID), monitor(11, rightID)]
        for useSavedNull in [false, true] {
            defaults.removeObject(forKey: ProjectionDisplayManager.assignmentKey)
            defaults.set(useSavedNull ? 10 : 0, forKey: AppDefaultsKey.projectorScreenDisplayID)
            if useSavedNull {
                // The previous UUID-based Auto preference overrides any stale numeric selection.
                defaults.set(Data("null".utf8), forKey: ProjectionDisplayManager.assignmentKey)
            }
            let manager = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
            let restored = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
            XCTAssertNil(manager.target)
            XCTAssertNil(restored.target)
            XCTAssertNil(restored.resolvedMonitor())
            XCTAssertTrue(restored.select(inventory[1].target))
            let selected = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
            XCTAssertEqual(selected.target, inventory[1].target)
            XCTAssertEqual(selected.resolvedMonitor(), inventory[1])
        }
    }

    func testMissingLegacyAndUnreadableAssignmentsRequireExplicitChoice() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(999, forKey: AppDefaultsKey.projectorScreenDisplayID)
        let inventory = [monitor(10, leftID)]
        let missing = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
        XCTAssertNotNil(missing.target)
        XCTAssertNil(missing.resolvedMonitor())
        defaults.set(Data("broken".utf8), forKey: ProjectionDisplayManager.assignmentKey)
        let unreadable = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
        XCTAssertNotNil(unreadable.target)
        XCTAssertNil(unreadable.resolvedMonitor())
        XCTAssertTrue(unreadable.select(inventory[0].target))
        XCTAssertEqual(unreadable.resolvedMonitor(), inventory[0])
    }

    func testMalformedLegacyAssignmentsNeverSilentlyChooseAMonitor() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let inventory = [monitor(10, leftID)]
        let values: [Any] = [-1, Int.max, "broken", true, 10.5]
        for value in values {
            defaults.removeObject(forKey: ProjectionDisplayManager.assignmentKey)
            defaults.set(value, forKey: AppDefaultsKey.projectorScreenDisplayID)
            let manager = ProjectionDisplayManager(defaults: defaults, displays: { inventory })
            XCTAssertNotNil(manager.target)
            XCTAssertNil(manager.resolvedMonitor())
        }
    }

    func testDisconnectedNamesRemainEditableAndDoNotChangeAssignment() {
        let inventory = MonitorInventory([monitor(10, leftID)])
        let target = inventory.displays[0].target
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        XCTAssertTrue(manager.select(target))
        inventory.displays = []
        manager.refresh()
        XCTAssertTrue(manager.canRename(target))
        XCTAssertTrue(manager.rename(target, to: " Main Projector "))
        XCTAssertEqual(manager.label(for: target), "1 · Main Projector")
        XCTAssertEqual(manager.target, target)
        XCTAssertFalse(manager.canIdentify(target))
        XCTAssertTrue(manager.rename(target, to: ""))
        XCTAssertEqual(manager.label(for: target), "1 · Same TV")
    }

    func testNameValidationRejectsControlsAndOverlongNames() {
        XCTAssertEqual(ProjectionDisplayManager.normalizedName("  Front Left TV  "), "Front Left TV")
        XCTAssertEqual(ProjectionDisplayManager.normalizedName(""), "")
        XCTAssertNotNil(ProjectionDisplayManager.normalizedName(String(repeating: "界", count: 40)))
        XCTAssertNil(ProjectionDisplayManager.normalizedName(String(repeating: "a", count: 41)))
        XCTAssertNil(ProjectionDisplayManager.normalizedName("Front\nLeft"))
        XCTAssertNil(ProjectionDisplayManager.normalizedName("Front\tLeft"))
    }

    func testSelectionAndIdentifyAreLockedDuringProjectionButNamingIsAvailable() {
        let inventory = [monitor(10, leftID), monitor(11, rightID)]
        let manager = ProjectionDisplayManager(displays: { inventory })
        XCTAssertTrue(manager.select(inventory[0].target))
        XCTAssertTrue(manager.canIdentify(inventory[0].target), "Selecting an idle monitor still permits Identify.")
        let owner = UUID()
        manager.lock(inventory[0].target, owner: owner)
        XCTAssertTrue(manager.isLocked)
        XCTAssertFalse(manager.select(inventory[1].target))
        XCTAssertFalse(manager.select(inventory[0].target))
        XCTAssertFalse(manager.canIdentify(inventory[0].target))
        XCTAssertTrue(manager.canIdentify(inventory[1].target))
        XCTAssertTrue(manager.rename(inventory[0].target, to: "Live Projector"))
        XCTAssertEqual(manager.target, inventory[0].target)
        manager.unlock(owner: owner)
        XCTAssertTrue(manager.select(inventory[1].target))
    }

    func testSelectionAndRenameRecheckInventoryBeforeNotificationArrives() {
        let inventory = MonitorInventory([monitor(10, leftID), monitor(11, rightID)])
        let manager = ProjectionDisplayManager(displays: { inventory.displays })
        let old = inventory.displays[0].target
        inventory.displays = [monitor(10, rightID)]
        XCTAssertFalse(manager.select(old))
        inventory.displays = [monitor(10, leftID), monitor(11, leftID)]
        XCTAssertFalse(manager.rename(old, to: "Wrong TV"))
    }

    func testUnavailableLegacyAssignmentNeverAdoptsALaterReusedID() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(10, forKey: AppDefaultsKey.projectorScreenDisplayID)
        let missing = ProjectionDisplayManager(defaults: defaults, displays: { [] })
        let saved = missing.target
        let restored = ProjectionDisplayManager(defaults: defaults, displays: { [self.monitor(10, self.rightID)] })
        XCTAssertEqual(restored.target, saved)
        XCTAssertNil(restored.resolvedMonitor())
        XCTAssertTrue(restored.select(restored.displays[0].target))
    }

    func testLegacyAmbiguousIdentityRequiresChoiceEvenAfterItBecomesUnique() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(10, forKey: AppDefaultsKey.projectorScreenDisplayID)
        let ambiguous = ProjectionDisplayManager(defaults: defaults, displays: {
            [self.monitor(10, self.leftID), self.monitor(11, self.leftID)]
        })
        XCTAssertNil(ambiguous.resolvedMonitor())
        let restored = ProjectionDisplayManager(defaults: defaults, displays: { [self.monitor(10, self.leftID)] })
        XCTAssertEqual(restored.target, ambiguous.target)
        XCTAssertNil(restored.resolvedMonitor())
    }

    func testUUIDSpellingIsCanonicalAndModelNameDoesNotControlAssignment() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let lowercase = "abcdefab-abcd-abcd-abcd-abcdefabcdef"
        defaults.set(Data("{\"identity\":\"\(lowercase)\",\"name\":\"Old model name\"}".utf8),
                     forKey: ProjectionDisplayManager.assignmentKey)
        let display = monitor(90, lowercase.uppercased())
        let restored = ProjectionDisplayManager(defaults: defaults, displays: { [display] })
        XCTAssertEqual(restored.target?.identity, lowercase.uppercased())
        XCTAssertEqual(restored.resolvedMonitor(), display)
    }

    func testWindowScreenCoordinatesNeverDoubleAnExternalScreenOffset() {
        for origin in [CGPoint.zero, CGPoint(x: 1920, y: 0), CGPoint(x: -1920, y: -100), CGPoint(x: 100, y: 1080)] {
            let global = CGRect(origin: origin, size: CGSize(width: 1920, height: 1080))
            let local = ProjectionScreenResolver.screenRelativeContentRect(for: global)
            XCTAssertEqual(local.offsetBy(dx: origin.x, dy: origin.y), global)
        }
    }

}

@MainActor
private final class MonitorInventory {
    var displays: [ProjectionMonitor]
    init(_ displays: [ProjectionMonitor]) { self.displays = displays }
}

/// Existing passage regressions explicitly choose an isolated synthetic monitor.
@MainActor
func selectedTestProjectionDisplays() -> ProjectionDisplayManager {
    let display = ProjectionMonitor(id: 10, identity: "11111111-1111-1111-1111-111111111111",
                                    name: "Fixture Monitor", frame: CGRect(x: -10000, y: -10000, width: 640, height: 360))
    let displays = ProjectionDisplayManager(displays: { [display] })
    precondition(displays.select(display.target))
    return displays
}
