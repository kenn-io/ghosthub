import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubSettings

struct SSHHostDraftListEditorTests {
    @Test("adding a host creates a unique host key and selects it")
    func addingHostCreatesUniqueKeyAndSelectsIt() throws {
        let existing = [
            draft(id: uuid(1), configKey: "fleet-host"),
            draft(id: uuid(2), configKey: "fleet-host-2"),
        ]
        let newID = uuid(3)

        let state = SSHHostDraftListEditor.addingDefaultHost(
            to: existing,
            id: newID
        )

        #expect(state.drafts.count == 3)
        let added = try #require(state.drafts.last)
        #expect(added.id == newID)
        #expect(added.configKey == "host")
        #expect(added.name == "Host")
        #expect(added.platform == .linux)
        #expect(added.sshDestination.isEmpty)
        #expect(state.selectedDraftID == newID)
    }

    @Test("removing selected host keeps selection near the removed row")
    func removingSelectedHostKeepsSelectionNearby() {
        let first = draft(id: uuid(1), configKey: "studio")
        let second = draft(id: uuid(2), configKey: "epyc")
        let third = draft(id: uuid(3), configKey: "lab")

        let middleRemoved = SSHHostDraftListEditor
            .removingSelectedHost(
                from: [first, second, third],
                selectedDraftID: second.id
            )
        #expect(middleRemoved.drafts.map(\.configKey) == [
            "studio", "lab",
        ])
        #expect(middleRemoved.selectedDraftID == third.id)

        let lastRemoved = SSHHostDraftListEditor.removingSelectedHost(
            from: [first, second, third],
            selectedDraftID: third.id
        )
        #expect(lastRemoved.drafts.map(\.configKey) == [
            "studio", "epyc",
        ])
        #expect(lastRemoved.selectedDraftID == second.id)
    }

    @Test("removing unknown selection preserves drafts and selection")
    func removingUnknownSelectionPreservesState() {
        let first = draft(id: uuid(1), configKey: "studio")
        let selectedID = uuid(99)

        let state = SSHHostDraftListEditor.removingSelectedHost(
            from: [first],
            selectedDraftID: selectedID
        )

        #expect(state.drafts == [first])
        #expect(state.selectedDraftID == selectedID)
    }

    @Test("importing SSH hosts maps host fields and uniquifies keys")
    func importingSSHHostsMapsFields() throws {
        let existing = [
            draft(id: uuid(1), configKey: "mac-mini"),
        ]
        let hosts = [
            SSHHostDraftImport(
                name: "Mac Mini",
                platform: .macOS,
                sshDestination: "mac-mini.tailnet.ts.net"
            ),
            SSHHostDraftImport(
                name: "Build Box",
                platform: .linux,
                sshDestination: "build-box.tailnet.ts.net"
            ),
        ]

        let state = SSHHostDraftListEditor.importingSSHHosts(
            hosts,
            into: existing
        )

        #expect(state.drafts.map(\.configKey) == [
            "mac-mini", "mac-mini-2", "build-box",
        ])
        let importedMac = state.drafts[1]
        #expect(importedMac.name == "Mac Mini")
        #expect(importedMac.platform == .macOS)
        #expect(importedMac.sshDestination == "mac-mini.tailnet.ts.net")

        let importedLinux = try #require(state.drafts.last)
        #expect(importedLinux.name == "Build Box")
        #expect(importedLinux.platform == .linux)
        #expect(importedLinux.sshDestination == "build-box.tailnet.ts.net")
        #expect(state.selectedDraftID == importedLinux.id)
    }

    @Test("SSH host imports map Tailscale peer identity")
    func sshHostImportsMapTailscalePeerIdentity() {
        let imported = SSHHostDraftImport(
            tailscalePeer: TailscalePeer(
                id: "node-1",
                hostName: "Mac Mini",
                dnsName: "mac-mini.tailnet.ts.net.",
                os: "macOS",
                isOnline: true
            ),
            username: "operator"
        )

        #expect(imported.name == "Mac Mini")
        #expect(imported.platform == .macOS)
        #expect(
            imported.sshDestination
                == "operator@mac-mini.tailnet.ts.net"
        )
    }

    private func draft(
        id: UUID,
        configKey: String
    ) -> SSHHostDraft {
        SSHHostDraft(
            id: id,
            configKey: configKey,
            name: configKey,
            platform: .linux,
            sshDestination: "\(configKey).example.com"
        )
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
