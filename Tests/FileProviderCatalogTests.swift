import XCTest
@testable import FreeMount

final class FileProviderCatalogTests: XCTestCase {
    private func descriptor() throws -> FileProviderConnectionDescriptor {
        try FileProviderConnectionDescriptor(remote: RemoteConfig(name: "Saved", provider: .googleDrive,
            bucketOrRootPath: "", keychainAccountKey: "fixture"))
    }
    func testEmptyCanonicalCatalogIgnoresStaleDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("catalog.json")
        try Data("[]".utf8).write(to: file)
        let defaults = EphemeralUserDefaults()
        defaults.set(try JSONEncoder().encode([descriptor()]), forKey: "fileProviderDomains.v1")
        XCTAssertTrue(try FileProviderDomainStore(defaults: defaults, catalogURL: file).all().isEmpty)
    }
    func testMigrationPublishesStableIdentityBeforeRetiringDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("catalog.json")
        let defaults = EphemeralUserDefaults()
        let original = try descriptor()
        defaults.set(try JSONEncoder().encode([original]), forKey: "fileProviderDomains.v1")
        let store = FileProviderDomainStore(defaults: defaults, catalogURL: file)
        XCTAssertEqual(try store.all(), [original])
        XCTAssertNil(defaults.data(forKey: "fileProviderDomains.v1"))
        XCTAssertEqual(try JSONDecoder().decode([FileProviderConnectionDescriptor].self, from: Data(contentsOf: file)), [original])
        XCTAssertNil(try store.connection(forDomainIdentifier: "unrelated." + original.domain.remoteID.uuidString.lowercased()))
    }
    func testFailedMigrationPreservesLegacyDefaults() throws {
        let defaults = EphemeralUserDefaults()
        let data = try JSONEncoder().encode([descriptor()])
        defaults.set(data, forKey: "fileProviderDomains.v1")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing/catalog.json")
        XCTAssertThrowsError(try FileProviderDomainStore(defaults: defaults, catalogURL: file).all())
        XCTAssertEqual(defaults.data(forKey: "fileProviderDomains.v1"), data)
    }
    func testCorruptCanonicalCatalogDoesNotFallBack() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("invalid".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let defaults = EphemeralUserDefaults()
        defaults.set(try JSONEncoder().encode([descriptor()]), forKey: "fileProviderDomains.v1")
        XCTAssertThrowsError(try FileProviderDomainStore(defaults: defaults, catalogURL: file).all())
    }
    func testLegacyFileMigratesWithoutChangingDomainIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("legacy.json")
        let canonical = directory.appendingPathComponent("catalog.json")
        let original = try descriptor()
        try JSONEncoder().encode([original]).write(to: legacy)
        let store = FileProviderDomainStore(defaults: EphemeralUserDefaults(), catalogURL: canonical, legacyCatalogURLs: [legacy])
        XCTAssertEqual(try store.all(), [original])
        XCTAssertEqual(try store.connection(forDomainIdentifier: original.id), original)
    }
    func testExtensionCannotPublishLegacyCatalog() throws {
        let defaults = EphemeralUserDefaults()
        let data = try JSONEncoder().encode([descriptor()])
        defaults.set(data, forKey: "fileProviderDomains.v1")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("catalog.json")
        let extensionStore = FileProviderDomainStore(defaults: defaults, catalogURL: file, permitsMigration: false)
        XCTAssertThrowsError(try extensionStore.all())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(defaults.data(forKey: "fileProviderDomains.v1"), data)
    }
}
