import Foundation
import Network
import Security

struct AltViewDestination: Codable, Equatable, Sendable {
    var name: String
    var host: String?
    var port: UInt16 = 49721
    var serviceDomain: String?

    init(name: String, host: String? = nil, port: UInt16 = 49721, serviceDomain: String? = nil) {
        self.name = name; self.host = host; self.port = port; self.serviceDomain = serviceDomain
    }
    init?(_ receiver: AltViewDiscoveredReceiver) {
        guard case .service(let name, _, let domain, _) = receiver.endpoint else { return nil }
        self.init(name: name, serviceDomain: domain)
    }
    var endpoint: NWEndpoint {
        if let host { return .hostPort(host: .init(host), port: .init(rawValue: port)!) }
        return .service(name: name, type: AltViewProtocol.serviceType, domain: serviceDomain ?? "local.", interface: nil)
    }
    var account: String {
        if let host { return "host:\(host.lowercased()):\(port)" }
        return "bonjour:\(name):\(serviceDomain ?? "local.")"
    }
    var isValid: Bool {
        if let host { return !host.isEmpty && !host.contains(where: \.isWhitespace) && port != 0 }
        return !name.isEmpty && serviceDomain != nil
    }
}

struct AltViewPairing: Codable, Sendable {
    let key: Data
    let receiverID: UUID
}

/// Keychain calls can block; this actor never runs on the presentation/UI queue.
protocol AltViewPairingStoring: Sendable {
    func read(account: String) async throws -> AltViewPairing?
    func save(_ pairing: AltViewPairing, account: String) async throws
}

actor AltViewPairingStore: AltViewPairingStoring {
    private let service = "suku.ViewTheWord.altview.pairing.v1"
    func read(account: String) throws -> AltViewPairing? {
        var item: CFTypeRef?
        let result = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain: true
        ] as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
        let pairing = try JSONDecoder().decode(AltViewPairing.self, from: data)
        guard AltViewPairingKey.isValid(pairing.key) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode)) }
        return pairing
    }
    func save(_ pairing: AltViewPairing, account: String) throws {
        let data = try JSONEncoder().encode(pairing)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: account, kSecUseDataProtectionKeychain: true]
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if result == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData] = data
            attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(attributes as CFDictionary, nil)
            guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        } else if result != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }
}
