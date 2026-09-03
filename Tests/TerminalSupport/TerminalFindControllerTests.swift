import Foundation
import Testing
@testable import GhosthubTerminalSupport

@Suite("Terminal Find controller")
@MainActor
struct TerminalFindControllerTests {
    @Test("latest query wins while one backend request is active")
    func latestQueryWins() async {
        let gate = FindTestGate()
        let recorder = FindSessionRecorder(firstSearchGate: gate)
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("n")
        await expectEventually { await recorder.searches == ["n"] }
        controller.updateQuery("ne")
        controller.updateQuery("needle")
        await gate.open()
        await expectEventually { await recorder.searches.count == 2 }

        #expect(await recorder.searches == ["n", "needle"])
        #expect(controller.query == "needle")
        #expect(await recorder.maximumActiveCalls == 1)
    }

    @Test("a replacement query cancels the active backend request")
    func replacementQueryCancelsActiveRequest() async {
        let recorder = FindSessionRecorder(
            firstSearchDelay: .milliseconds(250)
        )
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("first")
        await expectEventually { await recorder.searches == ["first"] }
        controller.updateQuery("second")
        await expectEventually {
            await recorder.searches == ["first", "second"]
        }

        #expect(await recorder.cancelledSearches == ["first"])
        #expect(controller.query == "second")
    }

    @Test("stale completion cannot overwrite the current result")
    func staleCompletionIsIgnored() async {
        let gate = FindTestGate()
        let recorder = FindSessionRecorder(
            firstSearchGate: gate,
            results: [
                "first": .match(total: 1, selected: nil),
                "second": .match(total: 2, selected: nil),
            ]
        )
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("first")
        await expectEventually { await recorder.searches == ["first"] }
        controller.updateQuery("second")
        await gate.open()
        await expectEventually {
            controller.result == .match(total: 2, selected: nil)
        }

        #expect(controller.result == .match(total: 2, selected: nil))
    }

    @Test("no match disables navigation")
    func noMatchDisablesNavigation() async {
        let recorder = FindSessionRecorder(results: ["missing": .noMatch])
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("missing")
        await expectEventually { controller.result == .noMatch }
        controller.findNext()
        controller.findPrevious()
        await Task.yield()

        #expect(!controller.canNavigate)
        #expect(await recorder.navigations.isEmpty)
    }

    @Test("close invalidates work and ends the backend session once")
    func closeEndsSession() async {
        let gate = FindTestGate()
        let recorder = FindSessionRecorder(firstSearchGate: gate)
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("needle")
        await expectEventually { await recorder.searches == ["needle"] }
        controller.close()
        controller.close()
        await gate.open()
        await expectEventually { await recorder.closeCount == 1 }

        #expect(!controller.isOpen)
        #expect(controller.result == .idle)
        #expect(await recorder.closeCount == 1)
    }

    @Test("closing Find cancels the active backend request")
    func closeCancelsActiveRequest() async {
        let recorder = FindSessionRecorder(
            firstSearchDelay: .milliseconds(250)
        )
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("needle")
        await expectEventually { await recorder.searches == ["needle"] }
        controller.close()
        await expectEventually { await recorder.closeCount == 1 }

        #expect(await recorder.cancelledSearches == ["needle"])
        #expect(!controller.isOpen)
    }

    @Test("callback-pending work completes from the backend callback")
    func callbackCompletesPendingWork() async {
        let recorder = FindSessionRecorder(
            responses: ["needle": .awaitingCallback]
        )
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("needle")
        await expectEventually {
            await recorder.searchTokens["needle"] != nil
        }
        let operation = await recorder.searchTokens["needle"]!
        controller.publishBackendSelected(0, operation: operation)
        controller.publishBackendTotal(3, operation: operation)

        #expect(controller.result == .match(total: 3, selected: 1))
        #expect(!controller.isWorking)
    }

    @Test("a search waits for its total callback")
    func searchWaitsForTotalCallback() async {
        let recorder = FindSessionRecorder(
            responses: ["needle": .awaitingCallback]
        )
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("needle")
        await expectEventually {
            await recorder.searchTokens["needle"] != nil
        }
        let operation = await recorder.searchTokens["needle"]!
        controller.publishBackendSelected(-1, operation: operation)

        #expect(controller.isWorking)
        #expect(controller.result == .idle)

        controller.publishBackendTotal(3, operation: operation)

        #expect(controller.result == .match(total: 3, selected: nil))
        #expect(!controller.isWorking)
    }

    @Test("navigation waits for its selected callback")
    func navigationWaitsForSelectedCallback() async {
        let recorder = FindSessionRecorder(
            results: ["needle": .match(total: 3, selected: nil)],
            navigationResponse: .awaitingCallback
        )
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("needle")
        await expectEventually {
            controller.result == .match(total: 3, selected: nil)
        }
        controller.findNext()
        await expectEventually { await recorder.navigationTokens.count == 1 }
        let operation = await recorder.navigationTokens[0]
        controller.publishBackendTotal(4, operation: operation)

        #expect(controller.isWorking)
        #expect(controller.result == .match(total: 4, selected: nil))

        controller.publishBackendSelected(1, operation: operation)

        #expect(controller.result == .match(total: 4, selected: 2))
        #expect(!controller.isWorking)
    }

    @Test("a delayed callback from an earlier query is ignored")
    func delayedEarlierQueryCallbackIsIgnored() async {
        let recorder = FindSessionRecorder(responses: [
            "first": .awaitingCallback,
            "second": .awaitingCallback,
        ])
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("first")
        await expectEventually {
            await recorder.searchTokens["first"] != nil
        }
        let firstOperation = await recorder.searchTokens["first"]!
        controller.updateQuery("second")
        controller.publishBackendTotal(1, operation: firstOperation)

        #expect(controller.query == "second")
        #expect(controller.result == .idle)
        await expectEventually {
            await recorder.searchTokens["second"] != nil
        }
        let secondOperation = await recorder.searchTokens["second"]!
        controller.publishBackendSelected(1, operation: secondOperation)
        controller.publishBackendTotal(2, operation: secondOperation)

        #expect(controller.result == .match(total: 2, selected: 2))
        #expect(!controller.isWorking)
    }

    @Test("an external search replaces a callback-pending operation")
    func externalSearchReplacesPendingCallback() async {
        let recorder = FindSessionRecorder(responses: [
            "internal": .awaitingCallback,
        ])
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: { recorder.session }
        )

        controller.open()
        controller.updateQuery("internal")
        await expectEventually {
            await recorder.searchTokens["internal"] != nil
        }
        let internalOperation = await recorder.searchTokens["internal"]!
        let externalOperation = TerminalFindOperationToken()
        controller.backendDidOpen(
            query: "external",
            operation: externalOperation
        )
        controller.publishBackendTotal(99, operation: internalOperation)
        controller.publishBackendSelected(1, operation: externalOperation)

        #expect(controller.result == .idle)

        controller.publishBackendTotal(4, operation: externalOperation)
        controller.publishBackendSelected(0, operation: internalOperation)

        #expect(controller.query == "external")
        #expect(controller.result == .match(total: 4, selected: 2))
        #expect(!controller.isWorking)
    }
}

private actor FindTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

private actor FindSessionRecorder {
    private let firstSearchGate: FindTestGate?
    private let firstSearchDelay: Duration?
    private let results: [String: TerminalFindResult]
    private let responses: [String: TerminalFindBackendResponse]
    private let navigationResponse: TerminalFindBackendResponse
    private(set) var searches: [String] = []
    private(set) var searchTokens: [String: TerminalFindOperationToken] = [:]
    private(set) var cancelledSearches: [String] = []
    private(set) var navigations: [TerminalFindDirection] = []
    private(set) var navigationTokens: [TerminalFindOperationToken] = []
    private(set) var closeCount = 0
    private var activeCalls = 0
    private(set) var maximumActiveCalls = 0

    init(
        firstSearchGate: FindTestGate? = nil,
        firstSearchDelay: Duration? = nil,
        results: [String: TerminalFindResult] = [:],
        responses: [String: TerminalFindBackendResponse] = [:],
        navigationResponse: TerminalFindBackendResponse = .result(
            .match(total: 1, selected: nil)
        )
    ) {
        self.firstSearchGate = firstSearchGate
        self.firstSearchDelay = firstSearchDelay
        self.results = results
        self.responses = responses
        self.navigationResponse = navigationResponse
    }

    nonisolated var session: TerminalFindSession {
        TerminalFindSession(
            search: { [self] query, operation in
                await search(query, operation: operation)
            },
            navigate: { [self] direction, operation in
                await navigate(direction, operation: operation)
            },
            close: { [self] in await close() }
        )
    }

    private func search(
        _ query: String,
        operation: TerminalFindOperationToken
    ) async -> Result<TerminalFindBackendResponse, TerminalFindFailure> {
        beginCall()
        defer { endCall() }
        searches.append(query)
        searchTokens[query] = operation
        if searches.count == 1, let firstSearchGate {
            await firstSearchGate.wait()
        }
        if searches.count == 1, let firstSearchDelay {
            do {
                try await Task.sleep(for: firstSearchDelay)
            } catch {
                cancelledSearches.append(query)
            }
        }
        return .success(
            responses[query]
                ?? .result(results[query] ?? .match(total: 1, selected: nil))
        )
    }

    private func navigate(
        _ direction: TerminalFindDirection,
        operation: TerminalFindOperationToken
    ) -> Result<TerminalFindBackendResponse, TerminalFindFailure> {
        beginCall()
        navigations.append(direction)
        navigationTokens.append(operation)
        endCall()
        return .success(navigationResponse)
    }

    private func close() -> TerminalFindFailure? {
        beginCall()
        closeCount += 1
        endCall()
        return nil
    }

    private func beginCall() {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
    }

    private func endCall() {
        activeCalls -= 1
    }
}

@MainActor
private func expectEventually(
    _ condition: @escaping @MainActor @Sendable () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0 ..< 1_000 {
        if await condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Condition did not become true.", sourceLocation: sourceLocation)
}
