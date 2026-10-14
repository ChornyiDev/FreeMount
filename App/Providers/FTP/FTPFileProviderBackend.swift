import Foundation
import os.log

/// Verifies connectivity to an FTP remote.
public actor FTPConnectionHealthChecker {
    private let keychain: KeychainService

    public init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
    }

    public func check(_ remote: RemoteConfig) async -> ConnectionHealth {
        do {
            let descriptor = try FileProviderConnectionDescriptor(remote: remote)
            let backend = try GenericRcloneFileProviderBackend.ftp(connection: descriptor, keychain: keychain)
            _ = try await backend.listChildren()
            return .healthy(checkedAt: Date())
        } catch {
            return Self.classify(error)
        }
    }

    public nonisolated static func classify(_ error: Error) -> ConnectionHealth {
        let details = error.localizedDescription.lowercased()
        if error is KeychainError || details.contains("permission denied") || details.contains("auth") || details.contains("530") || details.contains("password") {
            return .authorizationRequired(
                reason: "FTP authentication failed. Verify your username or password."
            )
        }
        return .unavailable(
            reason: "FTP server is unreachable. Check network connection and server status."
        )
    }
}

// MARK: - GenericRcloneFileProviderBackend FTP Extension

public extension GenericRcloneFileProviderBackend {
    /// Constructs a universal GenericRcloneFileProviderBackend configured for FTP.
    static func ftp(
        connection: FileProviderConnectionDescriptor,
        keychain: KeychainService = KeychainService(),
        client: RcloneClient? = nil,
        stagingContainer: URL? = nil
    ) throws -> GenericRcloneFileProviderBackend {
        guard connection.provider == .ftp else {
            throw FileProviderDomainError.unsupportedProvider(connection.provider)
        }
        let accountKey = connection.keychainAccountKey
        let rootPath = connection.rootPath
        let isReadOnly = connection.isReadOnly
        let remoteName = connection.domain.displayName

        return GenericRcloneFileProviderBackend(
            fsProvider: {
                let credential = try await keychain.loadCredential(account: accountKey)
                guard credential.provider == .ftp else {
                    throw FreeMountError.invalidConfiguration(
                        reason: "The linked Keychain credential for '\(remoteName)' is not an FTP credential."
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

public typealias FTPFileProviderBackend = GenericRcloneFileProviderBackend

/// Provider registration for FTP.
public enum FTPProvider {
    public static let registration = CloudProvider(
        id: .ftp,
        displayName: "FTP / FTPS",
        iconAssetName: "FTP",
        fallbackSystemIconName: "server.rack",
        accentColorHex: 0x34C759, // macOS system indigo
        backendFactory: { try GenericRcloneFileProviderBackend.ftp(connection: $0) },
        healthChecker: { remote in await FTPConnectionHealthChecker().check(remote) }
    )
}
