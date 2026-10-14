import Foundation

/// Represents a parsed host definition from an OpenSSH configuration file.
public struct SSHHostEntry: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { alias }
    public let alias: String
    public let hostName: String?
    public let user: String?
    public let port: Int?
    public let identityFile: String?
    public let proxyCommand: String?
    public let proxyJump: String?

    public init(
        alias: String,
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil,
        proxyCommand: String? = nil,
        proxyJump: String? = nil
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyCommand = proxyCommand
        self.proxyJump = proxyJump
    }

    /// Effective hostname to connect to (falls back to alias if hostName is not explicitly configured).
    public var effectiveHostName: String {
        let trimmed = hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? alias : trimmed
    }
}

/// Parser for standard OpenSSH configuration files (`~/.ssh/config`).
public enum SSHConfigParser {

    /// Standard path to user's SSH config.
    public static var defaultSSHConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config", isDirectory: false)
    }

    /// Loads and parses the user's standard `~/.ssh/config` if it exists.
    public static func loadStandardConfig() -> [SSHHostEntry] {
        let configURL = defaultSSHConfigURL
        guard FileManager.default.fileExists(atPath: configURL.path),
              let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            return []
        }
        return parse(content: content)
    }

    /// Parses the content of an OpenSSH configuration file.
    public static func parse(content: String) -> [SSHHostEntry] {
        var entries: [SSHHostEntry] = []
        var currentAliases: [String] = []
        var currentHostName: String?
        var currentUser: String?
        var currentPort: Int?
        var currentIdentityFile: String?
        var currentProxyCommand: String?
        var currentProxyJump: String?

        func flushCurrentBlock() {
            guard !currentAliases.isEmpty else { return }
            for alias in currentAliases {
                // Ignore wildcards (*, ?) as selectable user hosts
                if alias.contains("*") || alias.contains("?") {
                    continue
                }
                entries.append(
                    SSHHostEntry(
                        alias: alias,
                        hostName: currentHostName,
                        user: currentUser,
                        port: currentPort,
                        identityFile: currentIdentityFile,
                        proxyCommand: currentProxyCommand,
                        proxyJump: currentProxyJump
                    )
                )
            }
            currentAliases = []
            currentHostName = nil
            currentUser = nil
            currentPort = nil
            currentIdentityFile = nil
            currentProxyCommand = nil
            currentProxyJump = nil
        }

        let lines = content.components(separatedBy: .newlines)
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            // Ignore empty lines and comments
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let (directive, value) = parseDirectiveAndValue(line)
            guard let key = directive?.lowercased(), let val = value else { continue }

            if key == "host" {
                flushCurrentBlock()
                currentAliases = val.components(separatedBy: .whitespaces)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } else if key == "match" {
                // FreeMount targets static Host declarations; flush previous block on Match
                flushCurrentBlock()
            } else if !currentAliases.isEmpty {
                switch key {
                case "hostname":
                    if currentHostName == nil { currentHostName = val }
                case "user":
                    if currentUser == nil { currentUser = val }
                case "port":
                    if currentPort == nil, let p = Int(val), p > 0, p <= 65535 {
                        currentPort = p
                    }
                case "identityfile":
                    if currentIdentityFile == nil {
                        currentIdentityFile = expandTilde(val)
                    }
                case "proxycommand":
                    if currentProxyCommand == nil { currentProxyCommand = val }
                case "proxyjump":
                    if currentProxyJump == nil { currentProxyJump = val }
                default:
                    break
                }
            }
        }

        flushCurrentBlock()
        return entries
    }

    /// Helper to extract directive name and value (handles both space and '=' delimiters).
    private static func parseDirectiveAndValue(_ line: String) -> (String?, String?) {
        // Directives can be `Key Value` or `Key=Value`
        let delimiter: Character
        if let eqIdx = line.firstIndex(of: "="), let spaceIdx = line.firstIndex(where: { $0.isWhitespace }) {
            delimiter = eqIdx < spaceIdx ? "=" : " "
        } else if line.contains("=") {
            delimiter = "="
        } else {
            delimiter = " "
        }

        let parts = line.split(separator: delimiter, maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return (nil, nil) }

        let directive = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        var val = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip surrounding double quotes if present
        if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
            val = String(val.dropFirst().dropLast())
        }

        return (directive, val)
    }

    /// Expands `~` into user's home directory path.
    public static func expandTilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == "~" {
            return home
        } else if path.hasPrefix("~/") {
            return home + "/" + String(path.dropFirst(2))
        }
        return path
    }
}
