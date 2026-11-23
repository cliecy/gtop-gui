import Foundation
import Testing
@testable import GTopCore

struct SSHConfigParserTests {
    private let parser = SSHConfigParser()

    @Test("Parses multi-alias Host, Key=Value, quotes, inline comments, comment groups, and skips wildcards")
    func basicParsingMultiAliasWildcardAndComments() {
        let config = """
        # Global defaults
        Host *
            ServerAliveInterval 60
            User fallback

        # @group: H100 集群
        Host gpu-h100-01 gpu-h100-02 !gpu-bad *wildcard*
            HostName 10.20.30.40
            User=mlops
            Port 2222 # custom ssh port
            ProxyJump bastion-prod
            IdentityFile "~/.ssh/id ed25519"

        Host gpu-h100-01
            # Duplicate block should NOT overwrite first-seen HostName per OpenSSH semantics
            HostName 10.99.99.99
            User seconduser
        """

        let hosts = parser.parseContent(config, sourceFile: "/Users/test/.ssh/config")
        #expect(hosts.map(\.alias) == ["gpu-h100-01", "gpu-h100-02"])

        let first = hosts[0]
        #expect(first.hostName == "10.20.30.40")
        #expect(first.user == "mlops")
        #expect(first.port == 2222)
        #expect(first.proxyJump == "bastion-prod")
        #expect(first.identityFile == "~/.ssh/id ed25519")
        #expect(first.commentGroup == "H100 集群")
    }

    @Test("Recursively resolves Include globs with cycle safety")
    func recursiveIncludeAndCycleSafety() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gtop-ssh-test-\(UUID().uuidString)", isDirectory: true)
        let confD = tmpDir.appendingPathComponent("conf.d", isDirectory: true)
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let mainConfig = tmpDir.appendingPathComponent("config")
        let labConfig = confD.appendingPathComponent("lab.conf")
        let prodConfig = confD.appendingPathComponent("prod.conf")

        try """
        Include conf.d/*.conf

        Host github.com
            HostName github.com
            User git
        """.write(to: mainConfig, atomically: true, encoding: .utf8)

        // Include back to main config to verify cycle detection doesn't hang
        try """
        Include ../config

        Host lab-4090
            HostName 192.168.1.10
            User researcher
        """.write(to: labConfig, atomically: true, encoding: .utf8)

        try """
        Host prod-a100
            HostName 10.0.1.5
            User ops
        """.write(to: prodConfig, atomically: true, encoding: .utf8)

        let hosts = try parser.parseFile(at: mainConfig.path)
        #expect(hosts.map(\.alias) == ["lab-4090", "prod-a100", "github.com"])
        #expect(hosts.first(where: { $0.alias == "lab-4090" })?.sourceFileName == "lab.conf")
        #expect(hosts.first(where: { $0.alias == "prod-a100" })?.sourceFileName == "prod.conf")
    }
}
