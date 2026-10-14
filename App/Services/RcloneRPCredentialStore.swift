import Foundation
import Security

protocol RcloneRPCredentialPersistence: Sendable {
    func load() throws -> Data?
    /// False means another process inserted first; reload its credential.
    func insert(_ data: Data) throws -> Bool
}

/// Dedicated Data Protection item shared only by the signed host/extension.
/// There is deliberately no legacy Keychain or plaintext fallback.
private struct ProtectedRcloneRPCredentialPersistence: RcloneRPCredentialPersistence {
    private func query() throws -> [String: Any] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "FreeMountKeychainAccessGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { throw RcloneRPCAuthenticationError.missingAccessGroup }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.freemount.local-rpc",
                kSecAttrAccount as String: "installation-v1",
                kSecAttrAccessGroup as String: group,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: false]
    }
    func load() throws -> Data? {
        var query = try query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RcloneRPCAuthenticationError.keychain(status) }
        guard let data = result as? Data else { throw RcloneRPCAuthenticationError.invalidCredential }
        return data
    }
    func insert(_ data: Data) throws -> Bool {
        var query = try query()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw RcloneRPCAuthenticationError.keychain(status) }
        return true
    }
}

public actor RcloneRPCredentialStore {
    public static let shared = RcloneRPCredentialStore()
    public nonisolated static func loadSharedCredential() async throws -> RcloneRPCredentials {
        try await shared.load()
    }
    private let persistence: any RcloneRPCredentialPersistence
    public init() { persistence = ProtectedRcloneRPCredentialPersistence() }
    init(persistence: any RcloneRPCredentialPersistence) { self.persistence = persistence }

    public func load() throws -> RcloneRPCredentials {
        guard let data = try persistence.load() else { throw RcloneRPCAuthenticationError.missingCredential }
        do { return try JSONDecoder().decode(RcloneRPCredentials.self, from: data).validated() }
        catch { throw RcloneRPCAuthenticationError.invalidCredential }
    }
    /// Host-only initialization, never deletes or overwrites an existing item.
    public func loadOrCreate() throws -> RcloneRPCredentials {
        do { return try load() }
        catch RcloneRPCAuthenticationError.missingCredential {
            let credential = try RcloneRPCredentials.generate()
            if try persistence.insert(JSONEncoder().encode(credential)) { return credential }
            return try load()
        }
    }
}
