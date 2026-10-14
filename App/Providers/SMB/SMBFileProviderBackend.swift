import Foundation
import os.log

/// Verifies connectivity to an SMB remote.
public actor SMBConnectionHealthChecker {
    private let keychain: KeychainService

    public init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
    }

    public func check(_ remote: RemoteConfig) async -> ConnectionHealth {
        do {
            let descriptor = try FileProviderConnectionDescriptor(remote: remote)
            let backend = try GenericRcloneFileProviderBackend.smb(connection: descriptor, keychain: keychain)
            _ = try await backend.listChildren()
            return .healthy(checkedAt: Date())
        } catch {
            return Self.classify(error)
        }
    }

    public nonisolated static func classify(_ error: Error) -> ConnectionHealth {
        let details = error.localizedDescription.lowercased()
        if error is KeychainError || details.contains("permission denied") || details.contains("auth") || details.contains("logon_failure") || details.contains("access_denied") || details.contains("password") {
            return .authorizationRequired(
                reason: "SMB authentication failed. Verify your username, password, or domain."
            )
        }
        return .unavailable(
            reason: "SMB server is unreachable. Check network connection and server status."
        )
    }
}

// MARK: - GenericRcloneFileProviderBackend SMB Extension

public extension GenericRcloneFileProviderBackend {
    /// Constructs a universal GenericRcloneFileProviderBackend configured for SMB.
    static func smb(
        connection: FileProviderConnectionDescriptor,
        keychain: KeychainService = KeychainService(),
        client: RcloneClient? = nil,
        stagingContainer: URL? = nil
    ) throws -> GenericRcloneFileProviderBackend {
        guard connection.provider == .smb else {
            throw FileProviderDomainError.unsupportedProvider(connection.provider)
        }
        guard !connection.rootPath.isEmpty else { throw SMBConfigurationError.invalidShare }
        let accountKey = connection.keychainAccountKey
        let rootPath = connection.rootPath
        let isReadOnly = connection.isReadOnly
        let remoteName = connection.domain.displayName

        return GenericRcloneFileProviderBackend(
            fsProvider: {
                let credential = try await keychain.loadCredential(account: accountKey)
                guard credential.provider == .smb else {
                    throw FreeMountError.invalidConfiguration(
                        reason: "The linked Keychain credential for '\(remoteName)' is not an SMB credential."
                    )
                }
                return credential.fileSystemReference(root: rootPath)
            },
            isReadOnly: isReadOnly,
            client: client,
            stagingContainer: stagingContainer
        )
    }
}

public typealias SMBFileProviderBackend = GenericRcloneFileProviderBackend

/// Provider registration for SMB.
public enum SMBProvider {
    public static let registration = CloudProvider(
        id: .smb,
        displayName: "SMB",
        iconAssetName: "SMB",
        fallbackSystemIconName: "server.rack",
        accentColorHex: 0x5856D6, // macOS system indigo
        backendFactory: { try GenericRcloneFileProviderBackend.smb(connection: $0) },
        healthChecker: { remote in await SMBConnectionHealthChecker().check(remote) }
    )
}
