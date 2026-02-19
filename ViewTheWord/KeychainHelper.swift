import Foundation
import Security
import SwiftUI

/// Secure storage for sensitive data using macOS Keychain
class KeychainHelper {
    static let shared = KeychainHelper()

    private init() {}

    /// Save a string value to the Keychain
    /// - Parameters:
    ///   - value: The string value to save
    ///   - key: The key to identify this value
    /// - Returns: True if successful, false otherwise
    @discardableResult
    func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            logger.error("Failed to encode string to data for key: \(key)")
            return false
        }

        // Delete any existing item first
        delete(forKey: key)

        // Create query for adding new item
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.viewtheword.ViewTheWord",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecSuccess {
            logger.info("Successfully saved to Keychain: \(key)")
            return true
        } else {
            logger.error("Failed to save to Keychain: \(key), status: \(status)")
            return false
        }
    }

    /// Retrieve a string value from the Keychain
    /// - Parameter key: The key to identify the value
    /// - Returns: The stored string value, or nil if not found
    func retrieve(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.viewtheword.ViewTheWord",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess,
           let data = result as? Data,
           let string = String(data: data, encoding: .utf8) {
            return string
        } else if status == errSecItemNotFound {
            // Not an error, just not found
            return nil
        } else {
            logger.error("Failed to retrieve from Keychain: \(key), status: \(status)")
            return nil
        }
    }

    /// Delete a value from the Keychain
    /// - Parameter key: The key to identify the value
    /// - Returns: True if successful or item doesn't exist, false on error
    @discardableResult
    func delete(forKey key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.viewtheword.ViewTheWord"
        ]

        let status = SecItemDelete(query as CFDictionary)

        // Success or item not found are both OK
        if status == errSecSuccess || status == errSecItemNotFound {
            return true
        } else {
            logger.error("Failed to delete from Keychain: \(key), status: \(status)")
            return false
        }
    }

    /// Check if a value exists in the Keychain
    /// - Parameter key: The key to check
    /// - Returns: True if the value exists
    func exists(forKey key: String) -> Bool {
        return retrieve(forKey: key) != nil
    }

    /// Migrate a value from UserDefaults to Keychain (one-time migration)
    /// - Parameter key: The key to migrate
    func migrateFromUserDefaults(key: String) {
        _ = retrieveOrMigrateFromUserDefaults(forKey: key)
    }

    /// Retrieve from Keychain, or lazily migrate the same key from UserDefaults if needed.
    /// This avoids forced Keychain access at app launch.
    func retrieveOrMigrateFromUserDefaults(forKey key: String) -> String? {
        if let value = retrieve(forKey: key) {
            return value
        }

        guard let legacyValue = UserDefaults.standard.string(forKey: key), !legacyValue.isEmpty else {
            return nil
        }

        if save(legacyValue, forKey: key) {
            UserDefaults.standard.removeObject(forKey: key)
            logger.info("Successfully migrated and removed from UserDefaults: \(key)")
            return legacyValue
        }

        logger.error("Failed to migrate to Keychain: \(key)")
        return nil
    }
}

/// Property wrapper for Keychain storage with SwiftUI integration
@propertyWrapper
struct KeychainStorage: DynamicProperty {
    private let key: String
    private let defaultValue: String

    @State private var value: String

    init(wrappedValue defaultValue: String, _ key: String) {
        self.key = key
        self.defaultValue = defaultValue

        // Initialize with Keychain value (or lazily migrated legacy value) or default.
        let initialValue = KeychainHelper.shared.retrieveOrMigrateFromUserDefaults(forKey: key) ?? defaultValue
        self._value = State(initialValue: initialValue)
    }

    // Called by SwiftUI to refresh the property
    mutating func update() {
        // Intentionally no-op to avoid repeated keychain reads during normal view updates.
    }

    var wrappedValue: String {
        get { value }
        nonmutating set {
            value = newValue
            if newValue.isEmpty {
                KeychainHelper.shared.delete(forKey: key)
            } else {
                KeychainHelper.shared.save(newValue, forKey: key)
            }
        }
    }

    var projectedValue: Binding<String> {
        Binding(
            get: { wrappedValue },
            set: { wrappedValue = $0 }
        )
    }
}
