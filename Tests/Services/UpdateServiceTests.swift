import XCTest
@testable import FreeMount

final class UpdateServiceTests: XCTestCase {
    func testSemanticVersionComparison() {
        XCTAssertTrue(UpdateService.isVersion("v1.0.1", newerThan: "1.0.0"))
        XCTAssertTrue(UpdateService.isVersion("1.1.0", newerThan: "1.0.9"))
        XCTAssertTrue(UpdateService.isVersion("v2.0.0", newerThan: "v1.9.9"))
        XCTAssertTrue(UpdateService.isVersion("1.0.0.1", newerThan: "1.0.0"))

        XCTAssertFalse(UpdateService.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateService.isVersion("v1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateService.isVersion("0.9.9", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateService.isVersion("1.0.0", newerThan: "1.0.1"))
    }

    func testDecodeReleaseInfo() throws {
        let json = """
        {
            "tag_name": "v1.2.3",
            "name": "FreeMount v1.2.3",
            "body": "Fixed WebDAV reconnection.",
            "html_url": "https://github.com/ChornyiDev/FreeMount/releases/tag/v1.2.3",
            "published_at": "2026-10-31T12:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubReleaseInfo.self, from: json)

        XCTAssertEqual(release.tagName, "v1.2.3")
        XCTAssertEqual(release.name, "FreeMount v1.2.3")
        XCTAssertEqual(release.body, "Fixed WebDAV reconnection.")
        XCTAssertEqual(release.htmlUrl?.absoluteString, "https://github.com/ChornyiDev/FreeMount/releases/tag/v1.2.3")
        XCTAssertNotNil(release.publishedAt)
    }
}

