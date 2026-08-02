import Testing
@testable import GhosthubApp

@MainActor
@Suite("Workspace window registry")
struct WindowRegistryTests {
    @Test("captures live scenes in registration order")
    func capturesLiveScenesInRegistrationOrder() throws {
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
        let firstState = WorkspaceWindowState.fresh()
        let secondState = WorkspaceWindowState.fresh()
        registry.register(first) { firstState }
        registry.register(second) { secondState }

        #expect(
            registry.captureRestorationStates()
                == [firstState, secondState]
        )

        registry.unregister(first)
        #expect(registry.captureRestorationStates() == [secondState])
    }
}
