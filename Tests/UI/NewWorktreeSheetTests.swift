import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

@Suite("New worktree sheet")
struct NewWorktreeSheetTests {
    @Test("Escape cannot dismiss an active creation")
    func activeCreationCannotDismiss() {
        #expect(NewWorktreeSheetPolicy.canDismiss(isCreating: false))
        #expect(!NewWorktreeSheetPolicy.canDismiss(isCreating: true))
    }

    @Test("duplicate project names include host and repository location")
    func duplicateProjectNamesAreDisambiguated() {
        let firstHost = HostSummary.fixture(
            name: "Laptop",
            kind: .selfHost
        )
        let secondHost = HostSummary.fixture(
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: "wesm@builder"
        )
        let first = ProjectSummary.fixture(
            hostID: firstHost.id,
            name: "ghosthub",
            rootPath: "/Users/wesm/code/ghosthub"
        )
        let second = ProjectSummary.fixture(
            hostID: secondHost.id,
            name: "ghosthub",
            rootPath: "/srv/ghosthub"
        )

        let firstLabel = NewWorktreeProjectLabel.menuTitle(
            project: first,
            host: firstHost
        )
        let secondLabel = NewWorktreeProjectLabel.menuTitle(
            project: second,
            host: secondHost
        )

        #expect(firstLabel != secondLabel)
        #expect(firstLabel.contains("Laptop"))
        #expect(firstLabel.contains("/Users/wesm/code/ghosthub"))
        #expect(secondLabel.contains("wesm@builder"))
        #expect(secondLabel.contains("/srv/ghosthub"))
    }
}
