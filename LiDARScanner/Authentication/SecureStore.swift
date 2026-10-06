import Foundation
import Security

/// Key/value storage for secrets (password hashes, tokens).
protocol SecureStore: Sendable {
    func data(for key: String) throws -> Data?
    func set(_ data: Data, for key: String) throws
    func remove(_ key: String) throws
}

/// Keychain-backed store. Items are `kSecClassGenericPassword`, scoped to a
/// service name, and only accessible after first unlock on this device
/// (never migrated to other devices via backups).
struct KeychainSecureStore: SecureStore {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.example.lidarscanner") + ".auth") {
        self.service = service
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    func data(for key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw AuthError.storage("Keychain read failed (\(status)).")
        }
    }

    func set(_ data: Data, for key: String) throws {
        let query = baseQuery(key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { $1 }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AuthError.storage("Keychain write failed (\(status)).") }
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.storage("Keychain delete failed (\(status)).")
        }
    }
}

/// In-memory store for tests and UI tests (never used for real accounts).
final class InMemorySecureStore: SecureStore, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func data(for key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ data: Data, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = data
    }

    func remove(_ key: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = nil
    }
}
