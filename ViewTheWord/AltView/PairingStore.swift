import Foundation
import Network
import Security
import LocalAuthentication

struct AltViewDestination: Codable, Equatable, Sendable {
    var name: String
    var host: String?
    var port: UInt16 = 0
    var serviceDomain: String?
    var localReceiverID: UUID?

    init(name: String, host: String? = nil, port: UInt16 = 0, serviceDomain: String? = nil) {
        self.name = name; self.host = host; self.port = port; self.serviceDomain = serviceDomain; self.localReceiverID = nil
    }
    init?(_ receiver: AltViewDiscoveredReceiver) {
        if receiver.isLocal, let id = receiver.receiverID, case .hostPort(_, let port) = receiver.endpoint {
            self.init(name: receiver.name, host: "127.0.0.1", port: port.rawValue)
            localReceiverID = id
            return
        }
        guard case .service(let name, _, let domain, _) = receiver.endpoint else { return nil }
        self.init(name: name, serviceDomain: domain)
    }
    var endpoint: NWEndpoint {
        if let host { return .hostPort(host: .init(host), port: .init(rawValue: port)!) }
        return .service(name: name, type: AltViewProtocol.serviceType, domain: serviceDomain ?? "local.", interface: nil)
    }
    var account: String {
        if let localReceiverID { return "local:\(localReceiverID)" }
        if let host { return "host:\(host.lowercased()):\(port)" }
        return "bonjour:\(name):\(serviceDomain ?? "local.")"
    }
    var isValid: Bool {
        if localReceiverID != nil, host != "127.0.0.1" { return false }
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
    private let service: String
    private let keychain: any AltViewKeychainAccess

    init(service: String = "suku.ViewTheWord.altview.pairing.v1",
         keychain: any AltViewKeychainAccess = SystemAltViewKeychain()) {
        self.service = service; self.keychain = keychain
    }
    func read(account: String) throws -> AltViewPairing? {
        var data: Data?
        do { data = try keychain.read(service: service, account: account, dataProtection: true) }
        catch where Self.isMissingEntitlement(error) {}
        // Developer ID/local exports without a provisioning profile cannot use
        // the data-protection keychain. Preserve existing items there when it is
        // available; otherwise use the login Keychain's app-signature access rules.
        if data == nil { data = try keychain.read(service: service, account: account, dataProtection: false) }
        guard let data else { return nil }
        let pairing = try JSONDecoder().decode(AltViewPairing.self, from: data)
        guard AltViewPairingKey.isValid(pairing.key) else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode)) }
        return pairing
    }
    func save(_ pairing: AltViewPairing, account: String) throws {
        let data = try JSONEncoder().encode(pairing)
        do { try keychain.save(data, service: service, account: account, dataProtection: true) }
        catch where Self.isMissingEntitlement(error) {
            try keychain.save(data, service: service, account: account, dataProtection: false)
        }
    }
    private static func isMissingEntitlement(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSOSStatusErrorDomain && error.code == Int(errSecMissingEntitlement)
    }
}

/// Synchronous Security calls are made only by AltViewPairingStore's actor.
protocol AltViewKeychainAccess: Sendable {
    func read(service: String, account: String, dataProtection: Bool) throws -> Data?
    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws
}

struct SystemAltViewKeychain: AltViewKeychainAccess {
    private func query(service: String, account: String, dataProtection: Bool) -> [CFString: Any] {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: account, kSecUseDataProtectionKeychain: dataProtection,
         // Automatic startup must not leave a background Keychain prompt open.
         kSecUseAuthenticationContext: authentication]
    }
    func read(service: String, account: String, dataProtection: Bool) throws -> Data? {
        var query = query(service: service, account: account, dataProtection: dataProtection)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result == errSecSuccess ? errSecDecode : result))
        }
        return data
    }
    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws {
        let query = query(service: service, account: account, dataProtection: dataProtection)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if result == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData] = data
            if dataProtection { attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
            let result = SecItemAdd(attributes as CFDictionary, nil)
            guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        } else if result != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
    }
}
