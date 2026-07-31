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

    @Test(
        "pull request selectors accept numbers and pull URLs",
        arguments: [
            ("#32", "32"),
            (" 32 ", "32"),
            (
                "https://github.com/kenn-io/kwt/pull/32",
                "https://github.com/kenn-io/kwt/pull/32"
            ),
            ("PR import work", nil),
        ]
    )
    func pullRequestSelectors(
        input: String,
        expected: String?
    ) {
        #expect(PullRequestSelector.normalized(input) == expected)
    }

    @Test("branch search selects only an exact existing candidate")
    func exactExistingBranchSelection() {
        let branches = [
            WorktreeBranchCandidate(
                name: "feature/local",
                source: "feature/local",
                isRemote: false
            ),
            WorktreeBranchCandidate(
                name: "feature/remote",
                source: "origin/feature/remote",
                isRemote: true
            ),
        ]

        let matches = BranchQuery.matches(
            in: branches,
            query: "remote"
        )

        #expect(matches.map(\.name) == ["feature/remote"])
        #expect(
            BranchQuery.impliedSelectionSource(
                in: matches,
                query: "feature/remote"
            ) == "origin/feature/remote"
        )
        #expect(
            BranchQuery.impliedSelectionSource(
                in: matches,
                query: "feature/new"
            ) == nil
        )
    }

    @Test("duplicate remote branch names require an explicit source")
    func duplicateRemoteBranchSelection() {
        let branches = [
            WorktreeBranchCandidate(
                name: "topic",
                source: "origin/topic",
                isRemote: true
            ),
            WorktreeBranchCandidate(
                name: "topic",
                source: "upstream/topic",
                isRemote: true
            ),
        ]

        #expect(
            BranchQuery.selectionSource(
                in: branches,
                query: "topic",
                preserving: nil
            ) == nil
        )
        #expect(
            BranchQuery.selectionSource(
                in: branches,
                query: "topic",
                preserving: "upstream/topic"
            ) == "upstream/topic"
        )
        #expect(
            BranchQuery.selectionSource(
                in: branches,
                query: "different",
                preserving: "upstream/topic"
            ) == nil
        )
        #expect(!BranchQuery.canCreateBranch(
            in: branches,
            query: "topic"
        ))
        #expect(BranchQuery.canCreateBranch(
            in: branches,
            query: "new-topic",
            listIsAvailable: true
        ))
    }

    @Test("branch creation waits for successful branch discovery")
    func failedBranchDiscoveryDisablesCreation() {
        #expect(!BranchQuery.canCreateBranch(
            in: [],
            query: "feature/existing",
            listIsAvailable: false
        ))
    }

    private static func candidate(
        _ number: Int,
        title: String = "Some change",
        isImported: Bool = false
    ) -> PullRequestCandidate {
        PullRequestCandidate(
            id: "pr-\(number)",
            number: number,
            url: "https://github.com/kenn-io/kwt/pull/\(number)",
            title: title,
            author: "contributor",
            sourceBranch: "feature-\(number)",
            targetBranch: "main",
            isDraft: false,
            state: "open",
            isImported: isImported
        )
    }

    @Test("a typed number outranks longer numbers that merely contain it")
    func exactNumberOutranksSubstringMatches() {
        let candidates = [Self.candidate(132), Self.candidate(32)]

        let matches = PullRequestQuery.matches(in: candidates, query: "32")

        #expect(matches.map(\.number) == [32, 132])
        #expect(
            PullRequestQuery.impliedSelectionID(
                in: matches, query: "32"
            ) == "pr-32"
        )
    }

    @Test("an already imported exact match still wins the selection")
    func exactNumberWinsEvenWhenImported() {
        let candidates = [
            Self.candidate(132),
            Self.candidate(32, isImported: true),
        ]

        // A bare number is the ambiguous case. "#32" is not a substring of
        // "#132", so the leading hash already disambiguates on its own.
        let matches = PullRequestQuery.matches(in: candidates, query: "32")

        #expect(matches.map(\.number) == [32, 132])
        #expect(
            PullRequestQuery.impliedSelectionID(
                in: matches, query: "32"
            ) == "pr-32"
        )
    }

    @Test("text queries keep preferring a candidate that is not imported")
    func textQueryPrefersUnimportedCandidate() {
        let candidates = [
            Self.candidate(7, title: "Fix parser", isImported: true),
            Self.candidate(9, title: "Fix parser again"),
        ]

        let matches = PullRequestQuery.matches(
            in: candidates, query: "fix parser"
        )

        #expect(matches.map(\.number) == [7, 9])
        #expect(
            PullRequestQuery.impliedSelectionID(
                in: matches, query: "fix parser"
            ) == "pr-9"
        )
    }

    @Test("a number with no exact match still lists substring hits")
    func substringMatchesSurviveWithoutAnExactNumber() {
        let candidates = [Self.candidate(132), Self.candidate(232)]

        let matches = PullRequestQuery.matches(in: candidates, query: "32")

        #expect(matches.map(\.number) == [132, 232])
    }

    @Test("a number with no exact match never auto-selects a longer number")
    func numericQueryWithoutAnExactMatchLeavesSelectionEmpty() {
        let candidates = [Self.candidate(132), Self.candidate(232)]

        let matches = PullRequestQuery.matches(in: candidates, query: "32")

        #expect(
            PullRequestQuery.impliedSelectionID(
                in: matches, query: "32"
            ) == nil
        )
    }

    @Test("a typed number kwt has not listed still submits that number")
    func unlistedNumberSubmitsTheTypedSelector() {
        let candidates = [Self.candidate(132)]

        let matches = PullRequestQuery.matches(in: candidates, query: "32")
        let selection = PullRequestQuery.impliedSelectionID(
            in: matches, query: "32"
        )

        #expect(
            PullRequestQuery.importSelector(
                in: matches, query: "32", selectedID: selection
            ) == "32"
        )
    }

    @Test("explicitly picking a listed candidate submits that candidate")
    func explicitSelectionOutranksTheTypedSelector() {
        let candidates = [Self.candidate(132)]

        let matches = PullRequestQuery.matches(in: candidates, query: "32")

        #expect(
            PullRequestQuery.importSelector(
                in: matches, query: "32", selectedID: "pr-132"
            ) == "pr-132"
        )
    }

    @Test("a selection the filtered list dropped falls back to the query")
    func staleSelectionFallsBackToTheTypedSelector() {
        let candidates = [Self.candidate(132)]

        let matches = PullRequestQuery.matches(in: candidates, query: "32")

        #expect(
            PullRequestQuery.importSelector(
                in: matches, query: "32", selectedID: "pr-999"
            ) == "32"
        )
    }

    @Test("a text query with no selector submits nothing")
    func textQueryWithoutSelectionSubmitsNothing() {
        #expect(
            PullRequestQuery.importSelector(
                in: [], query: "parser", selectedID: nil
            ) == nil
        )
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
