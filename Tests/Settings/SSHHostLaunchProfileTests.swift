import Foundation
@testable import GhosthubSettings
import Testing

@Suite("SSH host launch profiles")
struct SSHHostLaunchProfileTests {
    @Test(
        "profile validation reports empty and duplicate fields",
        arguments: [
            ("", "echo ready", "Name is required."),
            ("Codex", " \n", "Command is required."),
            (" codex ", "echo ready", "Profile names must be unique."),
            ("REPL", "echo ready", nil),
        ] as [(String, String, String?)]
    )
    func validation(name: String, command: String, expected: String?) {
        let profile = TmuxLaunchProfile(name: name, command: command)
        let profiles = [
            TmuxLaunchProfile(name: "Codex", command: "exec codex"),
            profile,
        ]

        #expect(
            TmuxLaunchProfileValidation.message(
                for: profile,
                in: profiles
            ) == expected
        )
    }

    @Test("legacy hosts decode with no launch profiles")
    func legacyHostDecoding() throws {
        let data = Data("""
        {
          "configKey": "remote",
          "name": "Remote",
          "platform": "linux",
          "sshDestination": "dev.example"
        }
        """.utf8)

        let host = try JSONDecoder().decode(SSHHost.self, from: data)

        #expect(host.launchProfiles.isEmpty)
    }

    @Test("launch profiles round trip without changing user shell text")
    func profileRoundTrip() throws {
        let profileID = try #require(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let host = SSHHost(
            configKey: "remote",
            name: "Remote",
            platform: .linux,
            sshDestination: "dev.example",
            launchProfiles: [
                TmuxLaunchProfile(
                    id: profileID,
                    name: "Codex container",
                    command: "printf 'ready'\nexec codex"
                ),
            ]
        )

        let encoded = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(SSHHost.self, from: encoded)

        #expect(decoded == host)
        #expect(decoded.launchProfiles.first?.id == profileID)
        #expect(
            decoded.launchProfiles.first?.command
                == "printf 'ready'\nexec codex"
        )
    }
}
