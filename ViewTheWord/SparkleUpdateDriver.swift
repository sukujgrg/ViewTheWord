import AppKit
import Combine
import Sparkle

/// Sparkle owns download verification, sandboxed installation and relaunch.
/// Keep this adapter out of the offline SwiftPM and event-harness targets.
/// Its Objective-C delegate is called on the main thread but lacks actor annotations.
@MainActor
final class SparkleUpdateDriver: NSObject, AppUpdateDriving, @preconcurrency SPUStandardUserDriverDelegate {
    var onStateChange: ((AppUpdateState) -> Void)?
    private var availableVersion: String?
    private var subscriptions = Set<AnyCancellable>()
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self
    )

    var state: AppUpdateState {
        AppUpdateState(canCheckForUpdates: controller.updater.canCheckForUpdates,
                       automaticallyChecksForUpdates: controller.updater.automaticallyChecksForUpdates,
                       availableVersion: availableVersion)
    }

    func start() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] _ in self?.publishState() }.store(in: &subscriptions)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] _ in self?.publishState() }.store(in: &subscriptions)
        controller.startUpdater()
        publishState()
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    private func publishState() { onStateChange?(state) }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // A scheduled alert must never steal focus during a service, even at launch.
        // Every passage toolbar and the app menu can bring the update into focus.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        publishState()
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        publishState()
    }
}
