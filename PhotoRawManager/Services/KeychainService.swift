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
        cacheLock.lock(); cache[key] = value; negativeCache.remove(key); cacheLock.unlock()
        return status == errSecSuccess
    }

    // v8.6.1 fix: 기존 `[String: String?]` 은 `.some(nil)` 이 한 번 저장되면 영원히
    // 미인증 반환하는 버그 (dict["key"] 가 Optional<Optional<String>> 이라 .some(.none) 을
    // 찾으면 nil 반환). 해결: non-optional `[String: String]` 사용 + 별도 negative cache set.
    private static var cache: [String: String] = [:]
    private static var negativeCache: Set<String> = []
    private static let cacheLock = NSLock()

    /// Read a string value from Keychain (cached after first read)
    static func read(key: String) -> String? {
        cacheLock.lock()
        if let v = cache[key] { cacheLock.unlock(); return v }
        if negativeCache.contains(key) { cacheLock.unlock(); return nil }
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let value: String?
        if status == errSecSuccess, let data = result as? Data {
            value = String(data: data, encoding: .utf8)
        } else {
            value = nil
        }
        cacheLock.lock()
        if let v = value {
            cache[key] = v
            negativeCache.remove(key)
        } else {
            negativeCache.insert(key)
        }
        cacheLock.unlock()
        return value
    }

    /// Delete a value from Keychain
    static func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        cacheLock.lock()
        cache.removeValue(forKey: key)
        negativeCache.insert(key)
        cacheLock.unlock()
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
