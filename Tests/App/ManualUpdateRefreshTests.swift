import Foundation
import Testing
@testable import GhosthubApp

@MainActor
@Suite("Manual update refresh")
struct ManualUpdateRefreshTests {
    @Test("a newer release discards the queued offer before starting a new cycle")
    func replacesQueuedUpdate() async {
        var events: [String] = []
        let refresh = ManualUpdateRefresh(
            latestVersion: { "197" },
            checkAgain: { events.append("check") },
            showChecking: { _ in events.append("checking") },
            showError: { _, _ in Issue.record("Unexpected error") }
        )
        refresh.receiveOffer(
            version: "196", resuming: true,
            show: { events.append("offer") },
            skip: { events.append("skip") }
        )
        refresh.checkForUpdates()
        await refresh.task?.value
        #expect(events == ["offer", "checking", "skip"])
        refresh.updateCycleDidFinish()
        #expect(events == ["offer", "checking", "skip", "check"])
        refresh.updateCycleDidFinish()
        #expect(events.filter { $0 == "check" }.count == 1)
    }

    @Test(
        "a current or incompatible feed keeps the queued download",
        arguments: ["196", "195", nil]
    )
    func keepsQueuedUpdate(latest: String?) async {
        var shown = 0
        let refresh = ManualUpdateRefresh(
            latestVersion: { latest }, checkAgain: {}, showChecking: { _ in },
            showError: { _, _ in Issue.record("Unexpected error") }
        )
        refresh.checkForUpdates()
        refresh.receiveOffer(
            version: "196", resuming: true,
            show: { shown += 1 },
            skip: { Issue.record("Discarded a usable update") }
        )
        await refresh.task?.value
        #expect(shown == 1)
    }

    @Test("a failed check explains the failure and preserves the old offer")
    func failedCheck() async {
        var events: [String] = []
        let refresh = ManualUpdateRefresh(
            latestVersion: { throw URLError(.notConnectedToInternet) },
            checkAgain: {}, showChecking: { _ in },
            showError: { _, acknowledge in
                events.append("error")
                acknowledge()
            }
        )
        refresh.checkForUpdates()
        refresh.receiveOffer(
            version: "196", resuming: true,
            show: { events.append("offer") },
            skip: { Issue.record("Discarded a usable update") }
        )
        await refresh.task?.value
        #expect(events == ["error", "offer"])
    }

    @Test("a fresh Sparkle result does not trigger a second feed request")
    func freshResult() {
        var shown = false
        let refresh = ManualUpdateRefresh(
            latestVersion: { Issue.record("Redundant request")
                return nil
            },
            checkAgain: {}, showChecking: { _ in },
            showError: { _, _ in Issue.record("Unexpected error") }
        )
        refresh.checkForUpdates()
        refresh.receiveOffer(
            version: "197", resuming: false,
            show: { shown = true }, skip: {}
        )
        #expect(shown)
        #expect(refresh.task == nil)
    }

    @Test("cancelling a network check restores the offer without an error alert")
    func cancelledNetworkCheck() async {
        var cancel: (() -> Void)?
        var response: CheckedContinuation<String?, any Error>?
        var shown = 0
        let refresh = ManualUpdateRefresh(
            latestVersion: {
                try await withCheckedThrowingContinuation { response = $0 }
            },
            checkAgain: {}, showChecking: { cancel = $0 },
            showError: { _, acknowledge in
                Issue.record("Cancellation displayed an error")
                acknowledge()
            }
        )
        refresh.checkForUpdates()
        refresh.receiveOffer(version: "196", resuming: true, show: {
            shown += 1
        }, skip: { Issue.record("Cancellation discarded the update") })
        while response == nil {
            await Task.yield()
        }
        cancel?()
        response?.resume(throwing: URLError(.cancelled))
        await refresh.task?.value
        #expect(shown == 1)
    }

    @Test("a manually downloaded update can be replaced at the ready prompt")
    func refreshesReadyUpdate() async {
        var events: [String] = []
        let refresh = ManualUpdateRefresh(
            latestVersion: { "197" },
            checkAgain: { events.append("check") },
            showChecking: { _ in events.append("checking") },
            showError: { _, _ in Issue.record("Unexpected error") }
        )
        refresh.receiveOffer(version: "196", resuming: false, show: {}, skip: {
            Issue.record("Used obsolete pre-download reply")
        })
        refresh.userDidChoose()
        refresh.receiveReadyOffer(show: { events.append("ready") }, skip: {
            events.append("cancel installation")
        })
        refresh.checkForUpdates()
        await refresh.task?.value
        #expect(events == ["ready", "checking", "cancel installation"])
        refresh.updateCycleDidFinish()
        #expect(events.last == "check")
    }
}
