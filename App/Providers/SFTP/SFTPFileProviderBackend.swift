import Foundation
import os.log

/// Verifies connectivity to an SFTP remote.
public actor SFTPConnectionHealthChecker {
    private static let log = Logger(subsystem: "com.freemount.app", category: "SFTPConnectionHealthChecker")
    private let keychain: KeychainService

    public init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
    }

    public func check(_ remote: RemoteConfig) async -> ConnectionHealth {
        do {
            let descriptor = try FileProviderConnectionDescriptor(remote: remote)
            let backend = try GenericRcloneFileProviderBackend.sftp(connection: descriptor, keychain: keychain)
            _ = try await backend.listChildren()
            return .healthy(checkedAt: Date())
        } catch {
            Self.log.error("SFTP health check failed for \(remote.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return Self.classify(error)
        }
    }

    public nonisolated static func classify(_ error: Error) -> ConnectionHealth {
        let details = error.localizedDescription.lowercased()
        if error is KeychainError || details.contains("permission denied") || details.contains("auth") || details.contains("private key") || details.contains("password") {
            return .authorizationRequired(
                reason: "SFTP authentication failed. Verify your username, private key, or password."
            )
        }
        return .unavailable(
            reason: "SFTP server is unreachable. Check network connection and server status."
        )
    }
}

// MARK: - GenericRcloneFileProviderBackend SFTP Extension

public extension GenericRcloneFileProviderBackend {
    /// Constructs a universal GenericRcloneFileProviderBackend configured for SFTP.
    static func sftp(
        connection: FileProviderConnectionDescriptor,
        keychain: KeychainService = KeychainService(),
        client: RcloneClient? = nil,
        stagingContainer: URL? = nil
    ) throws -> GenericRcloneFileProviderBackend {
        guard connection.provider == .sftp else {
            throw FileProviderDomainError.unsupportedProvider(connection.provider)
        }
        let accountKey = connection.keychainAccountKey
        let rootPath = connection.rootPath
        let isReadOnly = connection.isReadOnly
        let remoteName = connection.domain.displayName

        return GenericRcloneFileProviderBackend(
            fsProvider: {
                let credential = try await keychain.loadCredential(account: accountKey)
                guard credential.provider == .sftp else {
                    throw FreeMountError.invalidConfiguration(
                        reason: "The linked Keychain credential for '\(remoteName)' is not an SFTP credential."
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

public typealias SFTPFileProviderBackend = GenericRcloneFileProviderBackend

/// Provider registration for SFTP.
public enum SFTPProvider {
    public static let registration = CloudProvider(
        id: .sftp,
        displayName: "SFTP",
        iconAssetName: "SFTP",
        fallbackSystemIconName: "terminal.fill",
        accentColorHex: 0xFF9500, // macOS system orange
        backendFactory: { try GenericRcloneFileProviderBackend.sftp(connection: $0) },
        healthChecker: { remote in await SFTPConnectionHealthChecker().check(remote) }
    )
}
