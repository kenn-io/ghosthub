import Testing
@testable import GhosthubApp

@MainActor
@Suite("Workspace window registry")
struct WindowRegistryTests {
    @Test("refreshes each live scene and drops unregistered scenes")
    func refreshesLiveSceneBindings() throws {
        let firstEnvironment = try setupHostEnvironment()
        let secondEnvironment = try setupHostEnvironment()
        let first = try makeModel(
            database: firstEnvironment.database,
            localHostID: firstEnvironment.host.id,
            snapshot: firstEnvironment.snapshot
        )
        let second = try makeModel(
            database: secondEnvironment.database,
            localHostID: secondEnvironment.host.id,
            snapshot: secondEnvironment.snapshot
        )
        let registry = WindowRegistry()
        var firstRefreshes = 0
        var secondRefreshes = 0
        registry.register(first) { firstRefreshes += 1 }
        registry.register(second) { secondRefreshes += 1 }

        registry.refreshRestorationStates()
        #expect(firstRefreshes == 1)
        #expect(secondRefreshes == 1)

        registry.unregister(first)
        registry.refreshRestorationStates()
        #expect(firstRefreshes == 1)
        #expect(secondRefreshes == 2)
    }
}
