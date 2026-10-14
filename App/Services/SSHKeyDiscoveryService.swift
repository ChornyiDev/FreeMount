import Foundation

/// Represents a discovered SSH private key on the local system.
public struct SSHPrivateKeyInfo: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let keyType: String

    public init(name: String, path: String, keyType: String) {
        self.name = name
        self.path = path
        self.keyType = keyType
    }

    /// Display label for UI pickers, e.g. "id_ed25519 (ED25519)".
    public var displayName: String {
        "\(name) (\(keyType))"
    }
}

/// Service to detect and list available SSH private keys in the user's environment.
public enum SSHKeyDiscoveryService {

    /// Default user SSH directory (`~/.ssh`).
    public static var defaultSSHDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
    }

    /// Known non-private-key filenames to ignore.
    private static let ignoredFilenames: Set<String> = [
        "config",
        "known_hosts",
        "known_hosts.old",
        "authorized_keys",
        "authorized_keys2",
        "environment",
        "rc"
    ]

    /// Scans the default `~/.ssh` directory for private keys.
    public static func discoverKeys() -> [SSHPrivateKeyInfo] {
        discoverKeys(in: defaultSSHDirectoryURL)
    }

    /// Scans a specific directory for private keys.
    public static func discoverKeys(in directoryURL: URL) -> [SSHPrivateKeyInfo] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [SSHPrivateKeyInfo] = []

        for url in items {
            let filename = url.lastPathComponent

            // Skip public keys (.pub), known system files, and backup copies
            if filename.hasSuffix(".pub") || filename.hasSuffix("~") || filename.hasSuffix(".bak") {
                continue
            }
            if ignoredFilenames.contains(filename.lowercased()) {
                continue
            }

            // Ensure it is a regular file
            guard let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile, isRegular else {
                continue
            }

            if let keyInfo = inspectKeyFile(at: url) {
                results.append(keyInfo)
            }
        }

        // Sort standard keys first (id_ed25519, id_rsa, etc.), then alphabetically
        return results.sorted { lhs, rhs in
            let lhsPriority = standardKeyPriority(lhs.name)
            let rhsPriority = standardKeyPriority(rhs.name)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Inspects a file to determine if it is an SSH private key and identifies its type.
    public static func inspectKeyFile(at url: URL) -> SSHPrivateKeyInfo? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Read the first 512 bytes to check the key header
        guard let data = try? handle.read(upToCount: 512),
              let header = String(data: data, encoding: .utf8) else {
            return nil
        }

        let filename = url.lastPathComponent
        let keyType: String

        if header.contains("BEGIN OPENSSH PRIVATE KEY") {
            if filename.lowercased().contains("ed25519") {
                keyType = "ED25519"
            } else if filename.lowercased().contains("ecdsa") {
                keyType = "ECDSA"
            } else if filename.lowercased().contains("rsa") {
                keyType = "RSA"
            } else {
                keyType = "OpenSSH"
            }
        } else if header.contains("BEGIN RSA PRIVATE KEY") {
            keyType = "RSA"
        } else if header.contains("BEGIN EC PRIVATE KEY") {
            keyType = "ECDSA"
        } else if header.contains("BEGIN DSA PRIVATE KEY") {
            keyType = "DSA"
        } else if header.contains("BEGIN PRIVATE KEY") {
            keyType = "PKCS#8"
        } else if filename.hasPrefix("id_") {
            // Standard fallback if header is proprietary or unformatted
            keyType = "SSH Key"
        } else {
            return nil
        }

        return SSHPrivateKeyInfo(name: filename, path: url.path, keyType: keyType)
    }

    private static func standardKeyPriority(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower == "id_ed25519" { return 0 }
        if lower == "id_rsa" { return 1 }
        if lower == "id_ecdsa" { return 2 }
        if lower == "id_dsa" { return 3 }
        if lower.hasPrefix("id_") { return 4 }
        return 5
    }
}
