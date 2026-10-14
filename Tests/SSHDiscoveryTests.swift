import XCTest
@testable import FreeMount

final class SSHDiscoveryTests: XCTestCase {

    // MARK: - SSHConfigParser Tests

    func testParseBasicHost() {
        let sampleConfig = """
        # My SSH Configuration
        Host my-server
            HostName 192.168.1.100
            User admin
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """

        let entries = SSHConfigParser.parse(content: sampleConfig)
        XCTAssertEqual(entries.count, 1)

        let entry = entries[0]
        XCTAssertEqual(entry.alias, "my-server")
        XCTAssertEqual(entry.hostName, "192.168.1.100")
        XCTAssertEqual(entry.effectiveHostName, "192.168.1.100")
        XCTAssertEqual(entry.user, "admin")
        XCTAssertEqual(entry.port, 2222)
        XCTAssertTrue(entry.identityFile?.hasSuffix("/.ssh/id_ed25519") ?? false)
        XCTAssertNil(entry.proxyCommand)
    }

    func testParseHostWithCloudflareProxyCommand() {
        let sampleConfig = """
        Host servroot
            HostName sshnew.chornyi.win
            User root
            ProxyCommand cloudflared access ssh --hostname %h
            IdentityFile ~/.ssh/id_ed25519
        """

        let entries = SSHConfigParser.parse(content: sampleConfig)
        XCTAssertEqual(entries.count, 1)

        let entry = entries[0]
        XCTAssertEqual(entry.alias, "servroot")
        XCTAssertEqual(entry.hostName, "sshnew.chornyi.win")
        XCTAssertEqual(entry.user, "root")
        XCTAssertEqual(entry.proxyCommand, "cloudflared access ssh --hostname %h")
        XCTAssertNil(entry.port)
        XCTAssertTrue(entry.identityFile?.hasSuffix("/.ssh/id_ed25519") ?? false)
    }

    func testParseMultipleHostsAndFilterWildcards() {
        let sampleConfig = """
        Host prod-bastion
            HostName bastion.example.com
            User devops
            Port 22

        Host internal-db
            HostName 10.0.0.50
            User postgres
            ProxyJump devops@bastion.example.com:22

        Host *
            ServerAliveInterval 60
            ForwardAgent yes
        """

        let entries = SSHConfigParser.parse(content: sampleConfig)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.alias), ["prod-bastion", "internal-db"])
        XCTAssertEqual(entries[1].proxyJump, "devops@bastion.example.com:22")
    }

    func testParseEqualsDelimiterAndQuotes() {
        let sampleConfig = """
        Host "quote-server"
            HostName="custom.host.net"
            User="root"
            Port=2200
        """

        let entries = SSHConfigParser.parse(content: sampleConfig)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].alias, "quote-server")
        XCTAssertEqual(entries[0].hostName, "custom.host.net")
        XCTAssertEqual(entries[0].user, "root")
        XCTAssertEqual(entries[0].port, 2200)
    }

    // MARK: - SSHKeyDiscoveryService Tests

    func testInspectKeyHeaders() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ed25519KeyURL = tempDir.appendingPathComponent("id_ed25519")
        let rsaKeyURL = tempDir.appendingPathComponent("id_rsa")
        let pubKeyURL = tempDir.appendingPathComponent("id_ed25519.pub")
        let configFileURL = tempDir.appendingPathComponent("config")

        try "-----BEGIN OPENSSH PRIVATE KEY-----\ntest-content".write(to: ed25519KeyURL, atomically: true, encoding: .utf8)
        try "-----BEGIN RSA PRIVATE KEY-----\ntest-content".write(to: rsaKeyURL, atomically: true, encoding: .utf8)
        try "ssh-ed25519 AAAAC3... user@host".write(to: pubKeyURL, atomically: true, encoding: .utf8)
        try "Host test\nHostName test.com".write(to: configFileURL, atomically: true, encoding: .utf8)

        let discovered = SSHKeyDiscoveryService.discoverKeys(in: tempDir)
        XCTAssertEqual(discovered.count, 2)

        // Priority sorting: id_ed25519 first, id_rsa second
        XCTAssertEqual(discovered[0].name, "id_ed25519")
        XCTAssertEqual(discovered[0].keyType, "ED25519")
        XCTAssertEqual(discovered[1].name, "id_rsa")
        XCTAssertEqual(discovered[1].keyType, "RSA")
    }

    // MARK: - SSHTunnelConfiguration Tests

    func testDirectTunnelReturnsNilCommand() {
        let tunnel = SSHTunnelConfiguration(type: .direct)
        XCTAssertFalse(tunnel.isTunneled)
        let cmd = tunnel.buildSSHCommand(host: "server.com", user: "root")
        XCTAssertNil(cmd)
    }

    func testCloudflareTunnelBuildsCommand() {
        let tunnel = SSHTunnelConfiguration(type: .cloudflare)
        XCTAssertTrue(tunnel.isTunneled)

        let cmd = tunnel.buildSSHCommand(
            host: "sshnew.chornyi.win",
            port: 22,
            user: "root",
            keyPath: "~/.ssh/id_ed25519"
        )

        XCTAssertNotNil(cmd)
        XCTAssertTrue(cmd!.contains("-o \"ProxyCommand=cloudflared access ssh --hostname %h\""))
        XCTAssertTrue(cmd!.contains("root@sshnew.chornyi.win"))
        XCTAssertTrue(cmd!.contains("-i "))
        XCTAssertFalse(cmd!.contains("-i ~/.ssh/id_ed25519")) // tilde expanded
        XCTAssertTrue(cmd!.hasSuffix("root@sshnew.chornyi.win"))
    }

    func testJumpHostBuildsCommand() {
        let tunnel = SSHTunnelConfiguration(type: .jumpHost, jumpHost: "bastion.corp.com:2222")
        let cmd = tunnel.buildSSHCommand(host: "10.0.0.5", port: 22, user: "admin")

        XCTAssertNotNil(cmd)
        XCTAssertTrue(cmd!.contains("-J bastion.corp.com:2222"))
        XCTAssertTrue(cmd!.contains("admin@10.0.0.5"))
    }

    func testCustomProxyCommand() {
        let tunnel = SSHTunnelConfiguration(type: .customProxyCommand, customCommand: "aws ssm start-session --target %h")
        let cmd = tunnel.buildSSHCommand(host: "i-0123456789", user: "ubuntu")

        XCTAssertNotNil(cmd)
        XCTAssertTrue(cmd!.contains("-o \"ProxyCommand=aws ssm start-session --target %h\""))
        XCTAssertTrue(cmd!.contains("ubuntu@i-0123456789"))
    }
}
