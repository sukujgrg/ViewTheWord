import Foundation
import Security
import XCTest
@testable import ViewTheWordCore

private final class FixtureAltViewKeychain: AltViewKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool: Data] = [:]
    private var calls: [Bool] = []
    let protectedError: OSStatus?

    init(protectedError: OSStatus? = nil, protectedData: Data? = nil, loginData: Data? = nil) {
        self.protectedError = protectedError
        values[true] = protectedData; values[false] = loginData
    }
    var backends: [Bool] { lock.withLock { calls } }
    func read(service: String, account: String, dataProtection: Bool) throws -> Data? {
        try lock.withLock {
            calls.append(dataProtection)
            if dataProtection, let protectedError { throw NSError(domain: NSOSStatusErrorDomain, code: Int(protectedError)) }
            return values[dataProtection]
        }
    }
    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws {
        try lock.withLock {
            calls.append(dataProtection)
            if dataProtection, let protectedError { throw NSError(domain: NSOSStatusErrorDomain, code: Int(protectedError)) }
            values[dataProtection] = data
        }
    }
}

final class AltViewPairingStoreTests: XCTestCase {
    func testUnprovisionedAppPairingSurvivesStoreRecreationAndReplacement() async throws {
        let keychain = FixtureAltViewKeychain(protectedError: errSecMissingEntitlement)
        let pairing = AltViewPairing(key: Data("ABCD2345".utf8), receiverID: UUID())
        let first = AltViewPairingStore(keychain: keychain)
        try await first.save(pairing, account: "receiver")
        let second = AltViewPairingStore(keychain: keychain)
        let restored = try await second.read(account: "receiver")
        XCTAssertEqual(restored?.key, pairing.key)
        XCTAssertEqual(restored?.receiverID, pairing.receiverID)
        XCTAssertEqual(keychain.backends, [true, false, true, false])
        let replacement = AltViewPairing(key: Data("ABCD2346".utf8), receiverID: UUID())
        try await second.save(replacement, account: "receiver")
        let updated = try await AltViewPairingStore(keychain: keychain).read(account: "receiver")
        XCTAssertEqual(updated?.key, replacement.key)
        XCTAssertEqual(updated?.receiverID, replacement.receiverID)
    }

    func testExistingProtectedPairingWinsAndLoginPairingSurvivesProvisioningChange() async throws {
        let pairing = AltViewPairing(key: Data("ABCD2345".utf8), receiverID: UUID())
        let data = try JSONEncoder().encode(pairing)
        let protected = FixtureAltViewKeychain(protectedData: data, loginData: Data("invalid".utf8))
        let saved = try await AltViewPairingStore(keychain: protected).read(account: "receiver")
        XCTAssertEqual(saved?.receiverID, pairing.receiverID)
        XCTAssertEqual(protected.backends, [true])
        let login = FixtureAltViewKeychain(loginData: data)
        let restored = try await AltViewPairingStore(keychain: login).read(account: "receiver")
        XCTAssertEqual(restored?.receiverID, pairing.receiverID)
        XCTAssertEqual(login.backends, [true, false])
    }

    func testLockedDeniedAndCorruptProtectedItemsAreNotHiddenByFallback() async throws {
        let pairing = AltViewPairing(key: Data("ABCD2345".utf8), receiverID: UUID())
        let data = try JSONEncoder().encode(pairing)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecDecode] {
            let keychain = FixtureAltViewKeychain(protectedError: status, loginData: data)
            let store = AltViewPairingStore(keychain: keychain)
            do { _ = try await store.read(account: "receiver"); XCTFail("Read must report \(status)") }
            catch { XCTAssertEqual((error as NSError).code, Int(status)) }
            do { try await store.save(pairing, account: "receiver"); XCTFail("Save must report \(status)") }
            catch { XCTAssertEqual((error as NSError).code, Int(status)) }
            XCTAssertEqual(keychain.backends, [true, true])
        }
        let corrupt = FixtureAltViewKeychain(protectedData: Data("invalid".utf8), loginData: data)
        do { _ = try await AltViewPairingStore(keychain: corrupt).read(account: "receiver"); XCTFail("Corruption must be reported") }
        catch { XCTAssertTrue(error is DecodingError) }
        XCTAssertEqual(corrupt.backends, [true])
    }
}
