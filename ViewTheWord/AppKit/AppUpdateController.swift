import AppKit
import Combine

struct AppUpdateState: Equatable {
    var canCheckForUpdates = false
    var automaticallyChecksForUpdates = true
    var availableVersion: String?
}

@MainActor
protocol AppUpdateDriving: AnyObject {
    var state: AppUpdateState { get }
    var onStateChange: ((AppUpdateState) -> Void)? { get set }
    func start()
    func checkForUpdates()
    func setAutomaticChecks(_ enabled: Bool)
}

/// One updater for the application, shared by every passage window.
/// Checking and presenting an update never changes navigation or live output.
@MainActor
final class AppUpdateController: NSObject, ObservableObject, NSMenuItemValidation {
    @Published private(set) var state: AppUpdateState
    private let driver: any AppUpdateDriving
    private var started = false

    init(driver: any AppUpdateDriving) {
        self.driver = driver
        state = driver.state
        super.init()
        driver.onStateChange = { [weak self] state in self?.state = state }
    }

    func start() {
        guard !started else { return }
        started = true
        driver.start()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard state.canCheckForUpdates else { return }
        driver.checkForUpdates()
    }

    @objc func toggleAutomaticChecks(_ sender: Any?) {
        driver.setAutomaticChecks(!state.automaticallyChecksForUpdates)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return state.canCheckForUpdates
        }
        if menuItem.action == #selector(toggleAutomaticChecks(_:)) {
            menuItem.state = state.automaticallyChecksForUpdates ? .on : .off
        }
        return true
    }
}
