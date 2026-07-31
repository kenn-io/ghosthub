import Testing
@testable import GhosthubWorkspace

struct TmuxSessionVisibilityTests {
    @Test(
        "wildcards hide matching session names",
        arguments: [
            ("forge-*", "forge-2ce60210419f1730", true),
            ("forge-*", "forge-", true),
            ("scratch-?", "scratch-a", true),
            ("scratch-?", "scratch-ab", false),
            ("forge-*", "Forge-2ce60210419f1730", false),
            ("forge-*", "homelab", false),
        ]
    )
    func wildcardMatching(
        pattern: String,
        sessionName: String,
        expectedHidden: Bool
    ) {
        let visibility = TmuxSessionVisibility(
            hiddenPatterns: [pattern]
        )

        #expect(visibility.isHidden(sessionName) == expectedHidden)
    }

    @Test("any matching pattern hides a session")
    func anyPatternHidesSession() {
        let visibility = TmuxSessionVisibility(
            hiddenPatterns: ["ci-*", "forge-*", "scratch-?"]
        )

        #expect(visibility.isHidden("forge-123"))
        #expect(!visibility.isHidden("homelab"))
    }
}
