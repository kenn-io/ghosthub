import GhosthubWorkspace
import Testing
@testable import GhosthubSettings

struct SSHHostSanitizerTests {
    @Test("SSH hosts trim required fields")
    func trimsRequiredFields() throws {
        let sanitized = SSHHostSanitizer.sshHosts([
            SSHHost(
                configKey: " studio ",
                name: " Studio ",
                platform: .macOS,
                sshDestination: " wes@studio.local "
            ),
        ])

        let host = try #require(sanitized.first)
        #expect(host.configKey == "studio")
        #expect(host.name == "Studio")
        #expect(host.sshDestination == "wes@studio.local")
    }

    @Test("configured hosts require an SSH destination")
    func requiresSSHDestination() {
        let sanitized = SSHHostSanitizer.sshHosts([
            SSHHost(
                configKey: "missing",
                name: "Missing",
                platform: .linux,
                sshDestination: ""
            ),
            SSHHost(
                configKey: "ready",
                name: "Ready",
                platform: .linux,
                sshDestination: "ready.example.com"
            ),
        ])

        #expect(sanitized.map(\.configKey) == ["ready"])
    }

    @Test("SSH hosts drop duplicate config keys")
    func dropsDuplicateConfigKeys() {
        let sanitized = SSHHostSanitizer.sshHosts([
            host(configKey: "studio", name: "First"),
            host(configKey: " studio ", name: "Second"),
            host(configKey: "epyc", name: "Third"),
        ])

        #expect(sanitized.map(\.name) == ["First", "Third"])
    }

    @Test("saved Tailscale destinations use the MagicDNS short hostname")
    func normalizesSavedTailscaleDestination() throws {
        let sanitized = SSHHostSanitizer.sshHosts([
            SSHHost(
                configKey: "remote-builder",
                name: "Remote Builder",
                platform: .linux,
                sshDestination: "operator@builder.example-tailnet.ts.net"
            ),
        ])

        let host = try #require(sanitized.first)
        #expect(host.sshDestination == "operator@builder")
    }

    private func host(configKey: String, name: String) -> SSHHost {
        SSHHost(
            configKey: configKey,
            name: name,
            platform: .linux,
            sshDestination: "host.example.com"
        )
    }
}
