import Foundation

/// Represents a GitHub Release payload subset needed for update inspection.
public struct GitHubReleaseInfo: Codable, Sendable, Equatable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlUrl: URL?
    public let publishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
    }
}

/// Status of the manual update check.
public enum UpdateCheckStatus: Sendable, Equatable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case updateAvailable(latestVersion: String, currentVersion: String, release: GitHubReleaseInfo)
    case failed(message: String)
}

/// Actor responsible for performing on-demand manual update checks against GitHub Releases.
public actor UpdateService {
    private let session: URLSession
    private let repositoryOwner: String
    private let repositoryName: String

    public init(
        session: URLSession = .shared,
        repositoryOwner: String = "ChornyiDev",
        repositoryName: String = "FreeMount"
    ) {
        self.session = session
        self.repositoryOwner = repositoryOwner
        self.repositoryName = repositoryName
    }

    /// Fetches the latest release from GitHub Releases API without downloading any binaries.
    public func fetchLatestRelease() async throws -> GitHubReleaseInfo {
        let endpoint = "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest"
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FreeMount-App", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 404 {
            // No releases published yet on the repository
            throw UpdateError.noReleasesFound
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw UpdateError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubReleaseInfo.self, from: data)
    }

    /// Compares two semantic version strings (e.g. "v1.0.1" vs "1.0.0").
    /// Returns true if `remote` is strictly higher than `current`.
    public static func isVersion(_ remote: String, newerThan current: String) -> Bool {
        let cleanRemote = cleanVersion(remote)
        let cleanCurrent = cleanVersion(current)

        let remoteParts = cleanRemote.split(separator: ".").compactMap { Int($0) }
        let currentParts = cleanCurrent.split(separator: ".").compactMap { Int($0) }

        let count = max(remoteParts.count, currentParts.count)
        for i in 0..<count {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    private static func cleanVersion(_ version: String) -> String {
        version.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case noReleasesFound
    case httpError(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .noReleasesFound:
            return "No official releases found on GitHub."
        case .httpError(let code):
            return "GitHub API responded with HTTP status \(code)."
        }
    }
}

