import Foundation
import Security

/// Secure credential storage using macOS Keychain
struct KeychainService {
    private static let serviceName = "com.pickshot.app"

    /// Save a string value to Keychain
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Read a string value from Keychain
    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a value from Keychain
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a key exists in Keychain
    static func exists(key: String) -> Bool {
        return read(key: key) != nil
    }

    // MARK: - Migration Helper

    /// Migrate a value from UserDefaults to Keychain (one-time)
    static func migrateFromUserDefaults(userDefaultsKey: String, keychainKey: String) {
        // Skip if already in Keychain
        if exists(key: keychainKey) { return }

        // Read from UserDefaults
        if let value = UserDefaults.standard.string(forKey: userDefaultsKey), !value.isEmpty {
            if save(key: keychainKey, value: value) {
                // Remove from UserDefaults after successful migration
                UserDefaults.standard.removeObject(forKey: userDefaultsKey)
                AppLogger.log(.performance, "Migrated \(keychainKey) from UserDefaults to Keychain")
            }
        }
    }
}
