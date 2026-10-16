import Combine
import Foundation

/// One Bonjour inventory and retry loop for every output destination.
@MainActor
final class AltViewDiscoveryService: ObservableObject {
    @Published private(set) var receivers: [AltViewDestination] = []
    @Published private(set) var note: String?
    private var clients = Set<UUID>()
    private var running = false
    private var retry: Task<Void, Never>?
    private var attempt = 0
    private let factory: (@escaping ([AltViewDiscoveredReceiver], String?) -> Void) -> any AltViewDiscovering
    private lazy var browser: any AltViewDiscovering = factory { [weak self] receivers, error in
        MainActor.assumeIsolated { self?.receive(receivers.compactMap(AltViewDestination.init), notice: error) }
    }
    init(factory: @escaping (@escaping ([AltViewDiscoveredReceiver], String?) -> Void) -> any AltViewDiscovering = { AltViewReceiverDiscovery(onChange: $0) }) {
        self.factory = factory
    }
    func request(_ id: UUID, needed: Bool) {
        if needed { clients.insert(id) } else { clients.remove(id) }
        let needed = !clients.isEmpty
        guard needed != running else { return }
        running = needed; retry?.cancel(); retry = nil; attempt = 0
        receivers = []; note = nil
        if needed { browser.start() } else { browser.stop() }
    }
    func receive(_ receivers: [AltViewDestination], notice: String?) {
        self.receivers = receivers; note = notice
        retry?.cancel(); retry = nil
        guard notice != nil, running else { if notice == nil { attempt = 0 }; return }
        let delay = AltViewSenderClient.reconnectDelay(attempt: attempt)
        attempt = min(attempt + 1, 5)
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.running else { return }
            self.retry = nil; self.receivers = []; self.browser.stop(); self.browser.start()
        }
    }
    func shutdown() {
        clients.removeAll(); retry?.cancel(); retry = nil
        if running { browser.stop() }; running = false
    }
    isolated deinit { retry?.cancel(); if running { browser.stop() } }
}
