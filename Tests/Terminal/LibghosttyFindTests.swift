import GhosthubTerminalSupport
import Testing
@testable import GhosthubTerminal

@Suite("libghostty Find callback routing")
struct LibghosttyFindTests {
    @Test("a replacement query does not claim delayed callbacks")
    func replacementWaitsForUpstreamReset() {
        let registry = LibghosttyFindOperationRegistry()
        let surfaceIdentity: UInt = 42
        let first = TerminalFindOperationToken()
        let replacement = TerminalFindOperationToken()

        registry.prepareSearch(
            first,
            for: surfaceIdentity
        )
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .total(0)
        ) == first)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .selected(-1)
        ) == first)
        registry.prepareSearch(
            replacement,
            for: surfaceIdentity
        )

        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .total(3)
        ) == first)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .selected(1)
        ) == first)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .total(0)
        ) == first)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .selected(-1)
        ) == first)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .total(2)
        ) == replacement)
    }

    @Test("queries queued before the first reset keep distinct operations")
    func queuedQueriesUseDistinctResetBoundaries() {
        let registry = LibghosttyFindOperationRegistry()
        let surfaceIdentity: UInt = 43
        let first = TerminalFindOperationToken()
        let replacement = TerminalFindOperationToken()

        registry.prepareSearch(first, for: surfaceIdentity)
        registry.prepareSearch(
            replacement,
            for: surfaceIdentity
        )

        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .total(0)
        ) == first)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .selected(-1)
        ) == first)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .total(4)
        ) == first)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .total(0)
        ) == first)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .selected(-1)
        ) == first)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .total(2)
        ) == replacement)
    }

    @Test("an external search supersedes a queued internal search")
    func externalSearchSupersedesQueuedSearch() {
        let registry = LibghosttyFindOperationRegistry()
        let surfaceIdentity: UInt = 44
        let internalOperation = TerminalFindOperationToken()

        registry.prepareSearch(internalOperation, for: surfaceIdentity)
        let externalOperation = registry.beginExternalOperation(
            for: surfaceIdentity
        )

        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .total(0)
        ) == internalOperation)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .selected(-1)
        ) == internalOperation)
        #expect(registry.operation(
            for: surfaceIdentity,
            callback: .total(4)
        ) == externalOperation)
    }
}
