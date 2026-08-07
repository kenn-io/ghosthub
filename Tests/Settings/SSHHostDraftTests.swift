import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubSettings

struct SSHHostDraftTests {
    @Test("draft preserves launch profiles through host conversion")
    func preservesLaunchProfiles() throws {
        let profileID = try #require(
            UUID(uuidString: "44444444-4444-4444-4444-444444444444")
        )
        let host = SSHHost(
            configKey: "remote",
            name: "Remote",
            platform: .linux,
            sshDestination: "dev.example",
            launchProfiles: [
                TmuxLaunchProfile(
                    id: profileID,
                    name: "Codex",
                    command: "docker exec -it codex codex"
                ),
            ]
        )

        let draft = SSHHostDraft(host)

        #expect(draft.launchProfiles == host.launchProfiles)
        #expect(draft.sshHost == host)
    }

    @Test("SSH host drafts preserve host identity")
    func preservesHostIdentity() {
        let host = SSHHost(
            configKey: "epyc",
            name: "EPYC",
            platform: .linux,
            sshDestination: "wes@epyc.local"
        )

        let draft = SSHHostDraft(host)

        #expect(draft.sshHost == host)
    }

    @Test("SSH host draft list display falls back for blank names")
    func listDisplayFallsBackForBlankNames() {
        let draft = SSHHostDraft(
            configKey: "blank",
            name: " \n ",
            platform: .linux,
            sshDestination: "builder.tailnet.ts.net"
        )

        #expect(draft.listDisplayName == "Untitled Host")
    }

    @Test("SSH host draft list subtitle shows the SSH destination")
    func listSubtitleShowsSSHDestination() {
        let connected = SSHHostDraft(
            configKey: "ssh",
            name: "SSH",
            platform: .linux,
            sshDestination: " builder.tailnet.ts.net "
        )
        let missing = SSHHostDraft(
            configKey: "missing-ssh",
            name: "Missing SSH",
            platform: .linux,
            sshDestination: " \n "
        )

        #expect(connected.listSubtitle == "builder.tailnet.ts.net")
        #expect(missing.listSubtitle == "SSH address required")
    }
}
