import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubSettings

struct SSHHostSanitizerTests {
    @Test("sanitizes launch profiles without changing their order")
    func sanitizesLaunchProfiles() throws {
        let firstID = try #require(
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        let duplicateID = try #require(
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        )
        let secondID = try #require(
            UUID(uuidString: "33333333-3333-3333-3333-333333333333")
        )
        let sanitized = SSHHostSanitizer.launchProfiles([
            TmuxLaunchProfile(
                id: firstID,
                name: " Codex ",
                command: "\n sudo docker exec -it codex codex \n"
            ),
            TmuxLaunchProfile(
                id: duplicateID,
                name: "codex",
                command: "should be dropped"
            ),
            TmuxLaunchProfile(name: "Blank command", command: " \n"),
            TmuxLaunchProfile(name: " \n", command: "echo ignored"),
            TmuxLaunchProfile(
                id: secondID,
                name: " REPL ",
                command: "printf 'one'\nprintf 'two'"
            ),
        ])

        #expect(sanitized.map(\.id) == [firstID, secondID])
        #expect(sanitized.map(\.name) == ["Codex", "REPL"])
        #expect(sanitized[0].command == "sudo docker exec -it codex codex")
        #expect(sanitized[1].command == "printf 'one'\nprintf 'two'")
    }

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

    @Test("saved Tailscale destinations preserve canonical MagicDNS identity")
    func preservesSavedTailscaleDestination() throws {
        let sanitized = SSHHostSanitizer.sshHosts([
            SSHHost(
                configKey: "remote-builder",
                name: "Remote Builder",
                platform: .linux,
                sshDestination: "operator@builder.example-tailnet.ts.net"
            ),
        ])

        let host = try #require(sanitized.first)
        #expect(
            host.sshDestination
                == "operator@builder.example-tailnet.ts.net"
        )
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
