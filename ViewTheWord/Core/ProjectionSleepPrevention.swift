import Foundation

/// Owns one activity for an open projection, independent of slides and controls.
/// Foundation's activity API is actor-independent; teardown releases it directly.
// The lock serializes activity ownership, including nonisolated owner teardown.
final class ProjectionSleepPrevention: @unchecked Sendable {
    private let lock = NSLock()
    private let beginActivity: (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    private let endActivity: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?

    init(beginActivity: @escaping (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: $0, reason: $1)
    }, endActivity: @escaping (NSObjectProtocol) -> Void = {
        ProcessInfo.processInfo.endActivity($0)
    }) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard activity == nil else { return }
        activity = beginActivity([.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                                 "Presenting ViewTheWord output")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let activity else { return }
        self.activity = nil
        endActivity(activity)
    }

    deinit {
        stop()
    }
}
