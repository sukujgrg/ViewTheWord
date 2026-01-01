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
            logger.fileError("Failed to encode string to data for key: \(key)")
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
            logger.fileInfo("Successfully saved to Keychain: \(key)")
            return true
        } else {
            logger.fileError("Failed to save to Keychain: \(key), status: \(status)")
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
            logger.fileError("Failed to retrieve from Keychain: \(key), status: \(status)")
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
            logger.fileError("Failed to delete from Keychain: \(key), status: \(status)")
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
        logger.fileInfo("Starting migration check for key: \(key)")

        // Check if already in Keychain
        if exists(forKey: key) {
            logger.fileInfo("Key already exists in Keychain, skipping migration: \(key)")
            if let value = retrieve(forKey: key) {
                logger.fileInfo("Current Keychain value length: \(value.count)")
            }
            return
        }

        logger.fileInfo("Key not in Keychain, checking UserDefaults...")

        // Try to get from UserDefaults
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty {
            logger.fileInfo("Found value in UserDefaults (length: \(value.count)), migrating to Keychain")

            // Save to Keychain
            if save(value, forKey: key) {
                // Remove from UserDefaults after successful migration
                UserDefaults.standard.removeObject(forKey: key)
                logger.fileInfo("Successfully migrated and removed from UserDefaults: \(key)")
            } else {
                logger.fileError("Failed to migrate to Keychain: \(key)")
            }
        } else {
            logger.fileInfo("No value found in UserDefaults to migrate for key: \(key)")
        }
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

        // Initialize with Keychain value or default
        let initialValue = KeychainHelper.shared.retrieve(forKey: key) ?? defaultValue
        logger.fileInfo("KeychainStorage init for '\(key)': value length = \(initialValue.count)")
        self._value = State(initialValue: initialValue)
    }

    // Called by SwiftUI to refresh the property
    mutating func update() {
        // Refresh value from Keychain on each update
        let currentValue = KeychainHelper.shared.retrieve(forKey: key) ?? defaultValue
        if value != currentValue {
            value = currentValue
        }
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
