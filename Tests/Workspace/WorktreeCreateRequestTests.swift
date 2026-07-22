import Foundation
import GhosthubWorkspace
import Testing

@Suite("Worktree creation request")
struct WorktreeCreateRequestTests {
    @Test(
        "accepts valid git branch names",
        arguments: [
            "feature/native-tmux",
            "fix-123",
            "release/2026.07",
            "user_name/topic",
        ]
    )
    func acceptsValidBranchName(_ name: String) {
        #expect(GitBranchName.isValid(name))
    }

    @Test(
        "rejects invalid git branch names",
        arguments: [
            "", " spaced", "spaced ", "two words", "-option", "@",
            "/leading", "trailing/", "two//slashes", "two..dots",
            "topic@{1}", ".hidden", "topic.", "topic.lock",
            "feature/.hidden", "line\nbreak", "back\\slash",
            "null\u{0000}byte", "vertical\u{000b}tab",
            "unit\u{001f}separator", "delete\u{007f}character",
        ]
    )
    func rejectsInvalidBranchName(_ name: String) {
        #expect(!GitBranchName.isValid(name))
    }
}
