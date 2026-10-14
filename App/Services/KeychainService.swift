import Foundation
import Security

/// Stores opaque credential payloads in the current user's macOS Keychain.
public actor KeychainService {
    public static let defaultServiceName = "com.freemount.credentials"

    public enum Storage: Sendable { case dataProtection, legacy }
    private let serviceName: String
    private let storage: Storage

    public init(serviceName: String = KeychainService.defaultServiceName, storage: Storage = .dataProtection) {
        self.serviceName = serviceName
        self.storage = storage
    }

    public func saveCredential(_ credential: RcloneRemoteCredential, account: String) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw KeychainError.invalidPayload(account: account)
        }
        try save(data: data, account: account)
    }

    /// Updates an existing secret atomically; a failed update preserves the old key.
    public func replaceCredential(_ credential: RcloneRemoteCredential, account: String) throws {
        let data: Data
        do { data = try JSONEncoder().encode(credential) }
        catch { throw KeychainError.invalidPayload(account: account) }
        // Loading explicitly migrates an older secret before atomic replacement.
        _ = try load(account: account)
        let status = SecItemUpdate(baseQuery(account: account, useDataProtection: storage == .dataProtection) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecSuccess else { throw makeError(operation: "replace", status: status) }
    }

    public func loadCredential(account: String) throws -> RcloneRemoteCredential {
        let data = try load(account: account)
        do {
            return try JSONDecoder().decode(RcloneRemoteCredential.self, from: data)
        } catch {
            throw KeychainError.invalidPayload(account: account)
        }
    }

    public func deleteCredential(account: String) throws {
        if storage == .legacy {
            let status = SecItemDelete(baseQuery(account: account, useDataProtection: false) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw makeError(operation: "delete", status: status) }
            return
        }
        let modern = SecItemDelete(baseQuery(account: account, useDataProtection: true) as CFDictionary)
        let legacy = SecItemDelete(baseQuery(account: account, useDataProtection: false) as CFDictionary)
        try Self.validateDeletionStatuses(modern: modern, legacy: legacy)
    }

    /// Both stores must be deleted or absent; one successful store cannot mask
    /// failure in the other store that may still contain the secret.
    static func validateDeletionStatuses(modern: OSStatus, legacy: OSStatus) throws {
        let allowedModern = [errSecSuccess, errSecItemNotFound]
        let allowedLegacy = [errSecSuccess, errSecItemNotFound]
        let failure = !allowedModern.contains(modern) ? modern : (!allowedLegacy.contains(legacy) ? legacy : nil)
        if let failure {
            let message = SecCopyErrorMessageString(failure, nil) as String? ?? "Unknown Security.framework error"
            throw KeychainError.operationFailed(operation: "delete", status: failure, message: message)
        }
    }

    /// Enumerates FreeMount-owned credentials for migration/recovery without
    /// exposing them outside the application process.
    public func listCredentials() throws -> [KeychainCredentialRecord] {
        let dpQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseDataProtectionKeychain as String: true
        ]
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var items: [[String: Any]] = []
        let queries = storage == .legacy ? [legacyQuery] : [dpQuery, legacyQuery]
        for query in queries {
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw makeError(operation: "list", status: status) }
            if let records = result as? [[String: Any]] { items.append(contentsOf: records) }
        }

        var seenAccounts = Set<String>()
        var records: [KeychainCredentialRecord] = []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { throw KeychainError.invalidPayload(account: "unknown") }
            guard seenAccounts.insert(account).inserted else { continue }
            // Failed access/migration is not an absent credential: callers must
            // preserve connection metadata rather than reconcile from a partial list.
            records.append(KeychainCredentialRecord(account: account, credential: try loadCredential(account: account)))
        }
        return records
    }

    private func save(data: Data, account: String) throws {
        try publish(data: data, account: account, useDataProtection: storage == .dataProtection)
    }

    /// Updating first preserves the existing secret if publication fails.
    private func publish(data: Data, account: String, useDataProtection: Bool) throws {
        let query = baseQuery(account: account, useDataProtection: useDataProtection)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw makeError(operation: "save", status: updated) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw makeError(operation: "save", status: status) }
    }

    private func read(account: String, useDataProtection: Bool) throws -> Data? {
        var query = baseQuery(account: account, useDataProtection: useDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw makeError(operation: "load", status: status) }
        return data
    }

    private func load(account: String) throws -> Data {
        if let data = try read(account: account, useDataProtection: storage == .dataProtection) { return data }
        guard storage == .dataProtection, let legacy = try read(account: account, useDataProtection: false) else {
            throw KeychainError.itemNotFound(account: account)
        }
        // This is migration, not a runtime fallback: publish before retirement.
        // Never migrate malformed payloads or fall back after denied modern access.
        guard (try? JSONDecoder().decode(RcloneRemoteCredential.self, from: legacy)) != nil else { throw KeychainError.invalidPayload(account: account) }
        var migration = baseQuery(account: account, useDataProtection: true)
        migration[kSecValueData as String] = legacy
        migration[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let published = SecItemAdd(migration as CFDictionary, nil)
        guard published == errSecSuccess || published == errSecDuplicateItem else { throw makeError(operation: "migrate", status: published) }
        // A concurrently published modern credential wins over the legacy value.
        guard let current = try read(account: account, useDataProtection: true) else { throw KeychainError.itemNotFound(account: account) }
        let retired = SecItemDelete(baseQuery(account: account, useDataProtection: false) as CFDictionary)
        guard retired == errSecSuccess || retired == errSecItemNotFound else { throw makeError(operation: "migrate", status: retired) }
        return current
    }

    /// Security.framework requires dictionary queries at this system boundary.
    private func baseQuery(account: String, useDataProtection: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func makeError(operation: String, status: OSStatus) -> KeychainError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Security.framework error"
        return .operationFailed(operation: operation, status: status, message: message)
    }
}

public struct KeychainCredentialRecord: Sendable, Equatable {
    public let account: String
    public let credential: RcloneRemoteCredential
}
