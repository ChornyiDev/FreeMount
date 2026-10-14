import Foundation
import os.log

/// Verifies connectivity to a WebDAV remote.
public actor WebDAVConnectionHealthChecker {
    private let keychain: KeychainService

    public init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
    }

    public func check(_ remote: RemoteConfig) async -> ConnectionHealth {
        do {
            let descriptor = try FileProviderConnectionDescriptor(remote: remote)
            let backend = try GenericRcloneFileProviderBackend.webdav(connection: descriptor, keychain: keychain)
            _ = try await backend.listChildren()
            return .healthy(checkedAt: Date())
        } catch {
            return Self.classify(error)
        }
    }

    public nonisolated static func classify(_ error: Error) -> ConnectionHealth {
        let details = error.localizedDescription.lowercased()
        if error is KeychainError
            || details.contains("unauthorized")
            || details.contains("401")
            || details.contains("403")
            || details.contains("forbidden")
            || details.contains("auth")
            || details.contains("password")
            || details.contains("token") {
            return .authorizationRequired(
                reason: "WebDAV authentication failed. Verify your username, password, or token."
            )
        }
        return .unavailable(
            reason: "WebDAV server is unreachable. Check your server URL, network connection, or SSL certificate."
        )
    }
}

// MARK: - GenericRcloneFileProviderBackend WebDAV Extension

public extension GenericRcloneFileProviderBackend {
    /// Constructs a universal GenericRcloneFileProviderBackend configured for WebDAV.
    static func webdav(
        connection: FileProviderConnectionDescriptor,
        keychain: KeychainService = KeychainService(),
        client: RcloneClient? = nil,
        stagingContainer: URL? = nil
    ) throws -> GenericRcloneFileProviderBackend {
        guard connection.provider == .webdav else {
            throw FileProviderDomainError.unsupportedProvider(connection.provider)
        }
        let accountKey = connection.keychainAccountKey
        let rootPath = connection.rootPath
        let isReadOnly = connection.isReadOnly
        let remoteName = connection.domain.displayName

        return GenericRcloneFileProviderBackend(
            fsProvider: {
                let credential = try await keychain.loadCredential(account: accountKey)
                guard credential.provider == .webdav else {
                    throw FreeMountError.invalidConfiguration(
                        reason: "The linked Keychain credential for '\(remoteName)' is not a WebDAV credential."
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

public typealias WebDAVFileProviderBackend = GenericRcloneFileProviderBackend

/// Provider registration for WebDAV.
public enum WebDAVProvider {
    public static let registration = CloudProvider(
        id: .webdav,
        displayName: "WebDAV",
        iconAssetName: "WebDAV",
        fallbackSystemIconName: "network",
        accentColorHex: 0x30B0C7, // cyan/teal
        backendFactory: { try GenericRcloneFileProviderBackend.webdav(connection: $0) },
        healthChecker: { remote in await WebDAVConnectionHealthChecker().check(remote) }
    )
}
