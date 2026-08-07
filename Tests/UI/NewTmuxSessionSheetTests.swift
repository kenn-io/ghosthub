import Foundation
import GhosthubSettings
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

@Suite("Tmux session names")
struct NewTmuxSessionSheetTests {
    @Test("launch selection defaults to login and resets with its host")
    func launchSelectionLifecycle() throws {
        let codexID = try #require(
            UUID(uuidString: "55555555-5555-5555-5555-555555555555")
        )
        let replID = try #require(
            UUID(uuidString: "66666666-6666-6666-6666-666666666666")
        )
        let configuredHosts = [
            SSHHost(
                configKey: "remote",
                name: "Remote",
                platform: .linux,
                sshDestination: "dev.example",
                launchProfiles: [
                    TmuxLaunchProfile(
                        id: codexID,
                        name: "Codex",
                        command: "exec codex"
                    ),
                    TmuxLaunchProfile(
                        id: replID,
                        name: "REPL",
                        command: "exec python"
                    ),
                ]
            ),
            SSHHost(
                configKey: "windows",
                name: "Windows",
                platform: .windows,
                sshDestination: "windows",
                launchProfiles: [
                    TmuxLaunchProfile(name: "Hidden", command: "ignored"),
                ]
            ),
        ]
        var selection = NewTmuxSessionLaunchSelection(
            hostConfigKey: "remote",
            hostKind: .remote
        )

        #expect(selection.selectedProfileID == nil)
        #expect(
            selection.availableProfiles(in: configuredHosts).map(\.id)
                == [codexID, replID]
        )
        #expect(selection.selectedCommand(in: configuredHosts) == nil)

        selection.selectProfile(codexID)
        #expect(selection.selectedCommand(in: configuredHosts) == "exec codex")
        #expect(selection.selectedProfileName(in: configuredHosts) == "Codex")

        selection.selectHost(configKey: "windows", kind: .remote)
        #expect(selection.selectedProfileID == nil)
        #expect(selection.availableProfiles(in: configuredHosts).isEmpty)
        #expect(selection.selectedCommand(in: configuredHosts) == nil)
    }

    @Test("local host never resolves a colliding remote profile")
    func localHostIgnoresCollidingConfigKey() {
        let profile = TmuxLaunchProfile(
            name: "Codex",
            command: "exec codex"
        )
        let configuredHosts = [
            SSHHost(
                configKey: "local",
                name: "Local",
                platform: .linux,
                sshDestination: "host-a.example",
                launchProfiles: [profile]
            ),
        ]
        var selection = NewTmuxSessionLaunchSelection(
            hostConfigKey: "local",
            hostKind: .selfHost
        )

        #expect(selection.availableProfiles(in: configuredHosts).isEmpty)
        selection.selectProfile(profile.id)
        #expect(selection.selectedCommand(in: configuredHosts) == nil)

        selection.selectHost(configKey: "local", kind: .remote)
        #expect(
            selection.availableProfiles(in: configuredHosts).map(\.id)
                == [profile.id]
        )

        selection.selectHost(configKey: "local", kind: .selfHost)
        #expect(selection.selectedProfileID == nil)
        #expect(selection.availableProfiles(in: configuredHosts).isEmpty)
    }

    @Test("creation requests keep command intent out of session identity")
    func creationRequestIdentity() {
        let session = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "codex"
        )
        let request = WorkspaceTmuxSessionCreationRequest(
            selection: session,
            initialCommand: "exec codex"
        )

        #expect(request.selection == session)
        #expect(request.initialCommand == "exec codex")
        #expect(
            request != WorkspaceTmuxSessionCreationRequest(
                selection: session,
                initialCommand: nil
            )
        )
    }

    @Test(
        "validates tmux session names",
        arguments: [
            ("docbank", true),
            ("  release work  ", true),
            ("", false),
            ("   ", false),
            ("has.period", false),
            ("has:colon", false),
            ("has\nnewline", false),
        ]
    )
    func validates(name: String, expected: Bool) {
        #expect(TmuxSessionName.isValid(name) == expected)
    }
}
