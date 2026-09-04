import GhosthubWorkspace
import Testing
@testable import GhosthubUI

@Suite("worktree changes presentation")
struct WorktreeChangesViewTests {
    @Test(
        "semantic states have readable compact labels",
        arguments: WorktreeFileState.allCases
    )
    func semanticLabels(_ state: WorktreeFileState) {
        #expect(!WorktreeFileChangePresentation.label(for: state).isEmpty)
        #expect(!WorktreeFileChangePresentation.symbol(for: state).isEmpty)
    }

    @Test("accessibility describes staged and working tree states")
    func accessibilityValue() {
        let file = WorktreeFileChange(
            path: "Sources/New.swift",
            originalPath: "Sources/Old.swift",
            index: .renamed,
            worktree: .modified
        )

        #expect(WorktreeFileChangePresentation.accessibilityValue(for: file)
            ==
            "Sources/New.swift, renamed from Sources/Old.swift, staged renamed, working tree modified")
    }

    @Test("accessibility distinguishes copied files from renamed files")
    func copiedAccessibilityValue() {
        let file = WorktreeFileChange(
            path: "Sources/Copy.swift",
            originalPath: "Sources/Original.swift",
            index: .copied,
            worktree: nil
        )

        #expect(WorktreeFileChangePresentation.accessibilityValue(for: file)
            ==
            "Sources/Copy.swift, copied from Sources/Original.swift, staged copied")
    }

    @Test("retry is offered only when refresh has an effect")
    func retryAvailability() {
        var failed = WorktreeChangesEntry()
        failed.errorMessage = "Unavailable"

        #expect(WorktreeChangesPresentation.showsRetry(
            for: failed,
            canRefresh: true
        ))
        #expect(!WorktreeChangesPresentation.showsRetry(
            for: failed,
            canRefresh: false
        ))
    }

    @Test("file states use the familiar two-column Git status")
    func statusCode() {
        #expect(
            WorktreeFileChangePresentation.statusCode(
                index: nil,
                worktree: .untracked
            ) == "??"
        )
        #expect(
            WorktreeFileChangePresentation.statusCode(
                index: nil,
                worktree: .modified
            ) == " M"
        )
        #expect(
            WorktreeFileChangePresentation.statusCode(
                index: .modified,
                worktree: nil
            ) == "M "
        )
        #expect(
            WorktreeFileChangePresentation.statusCode(
                index: .modified,
                worktree: .modified
            ) == "MM"
        )
        #expect(
            WorktreeFileChangePresentation.statusCode(
                index: .renamed,
                worktree: .deleted
            ) == "RD"
        )
    }

    @Test("loading chrome appears only before the first successful value")
    func loadingChrome() {
        var initial = WorktreeChangesEntry()
        initial.isLoading = true

        var refreshing = initial
        refreshing.hasSuccessfulValue = true

        #expect(WorktreeChangesPresentation.showsLoadingChrome(for: initial))
        #expect(!WorktreeChangesPresentation.showsLoadingChrome(
            for: refreshing
        ))
    }

    @Test("initial and manual loads share one activity indicator")
    func activityIndicator() {
        var initial = WorktreeChangesEntry()
        initial.isLoading = true

        var manual = initial
        manual.hasSuccessfulValue = true

        var timer = WorktreeChangesEntry()
        timer.hasSuccessfulValue = true

        #expect(WorktreeChangesPresentation.showsActivityIndicator(
            for: initial
        ))
        #expect(WorktreeChangesPresentation.showsActivityIndicator(
            for: manual
        ))
        #expect(!WorktreeChangesPresentation.showsActivityIndicator(
            for: timer
        ))
    }

    @Test("large change sets reveal files in bounded pages")
    func boundedFilePages() {
        let files = (0 ..< 205).map { index in
            WorktreeFileChange(
                path: "file-\(index)",
                originalPath: nil,
                index: nil,
                worktree: .modified
            )
        }

        let first = WorktreeChangesPresentation.page(
            files: files,
            requestedCount: 200
        )
        let second = WorktreeChangesPresentation.page(
            files: files,
            requestedCount: first.nextRequestedCount
        )

        #expect(first.files.count == 200)
        #expect(first.remainingCount == 5)
        #expect(second.files.count == 205)
        #expect(second.remainingCount == 0)
    }

    @Test("refreshes preserve the requested page depth")
    func requestedPageDepthSurvivesRefresh() {
        #expect(WorktreeChangesPresentation.adjustedRequestedCount(
            600,
            forFileCount: 800
        ) == 600)
        #expect(WorktreeChangesPresentation.adjustedRequestedCount(
            600,
            forFileCount: 350
        ) == 350)
        #expect(WorktreeChangesPresentation.adjustedRequestedCount(
            200,
            forFileCount: 50
        ) == 200)
    }
}
