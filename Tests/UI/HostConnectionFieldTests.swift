import Foundation
import Testing
import GhosthubSettings
import GhosthubWorkspace
@testable import GhosthubUI

@Suite("Host connection keyboard navigation")
struct HostConnectionFieldTests {
    @Test("Tab moves from display name to SSH address")
    func movesForward() {
        #expect(
            HostConnectionField.adjacent(
                to: .displayName,
                backwards: false
            ) == .sshAddress
        )
        #expect(
            HostConnectionField.adjacent(
                to: .sshAddress,
                backwards: false
            ) == nil
        )
    }

    @Test("Shift-Tab moves from SSH address to display name")
    func movesBackward() {
        #expect(
            HostConnectionField.adjacent(
                to: .sshAddress,
                backwards: true
            ) == .displayName
        )
        #expect(
            HostConnectionField.adjacent(
                to: .displayName,
                backwards: true
            ) == nil
        )
    }
}

@Suite("Host operation identity")
struct HostOperationTargetTests {
    @Test("results apply only to the selected unchanged endpoint")
    func matchesSelectedEndpoint() {
        let draft = SSHHostDraft(
            configKey: "spark",
            name: "DGX Spark",
            platform: .linux,
            sshDestination: "wesm@spark"
        )
        let target = HostOperationTarget(draft)

        #expect(target.isCurrent(
            selectedDraftID: draft.id,
            drafts: [draft]
        ))

        var changedEndpoint = draft
        changedEndpoint.sshDestination = "wesm@spark-new"
        #expect(!target.isCurrent(
            selectedDraftID: draft.id,
            drafts: [changedEndpoint]
        ))

        #expect(!target.isCurrent(
            selectedDraftID: UUID(),
            drafts: [draft]
        ))
    }
}
