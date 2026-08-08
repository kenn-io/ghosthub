import Combine
import Foundation
import Testing
@testable import GhosthubApp

@MainActor
@Suite("Herdr session lifecycle coordination")
struct HerdrSessionLifecycleCoordinatorTests {
    @Test("same-session mutations serialize while other sessions proceed")
    func serializationAndEvents() throws {
        let coordinator = HerdrSessionLifecycleCoordinator()
        let hostID = UUID()
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: hostID,
            sessionName: "review"
        )
        let otherKey = HerdrSessionLifecycleCoordinator.Key(
            hostID: hostID,
            sessionName: "worker"
        )
        var phases: [HerdrSessionLifecycleCoordinator.Phase] = []
        let cancellable = coordinator.events.sink {
            phases.append($0.phase)
        }
        defer { cancellable.cancel() }

        let operation = try #require(coordinator.begin(.stop, key: key))
        #expect(coordinator.begin(.delete, key: key) == nil)
        let other = try #require(coordinator.begin(.restart, key: otherKey))
        #expect(coordinator.isPending(key))

        coordinator.willStop(operation)
        coordinator.finish(operation, outcome: .succeeded)
        coordinator.finish(operation, outcome: .failed)
        coordinator.finish(other, outcome: .failed)

        #expect(phases == [
            .began, .began, .willStop, .succeeded, .failed,
        ])
        #expect(!coordinator.isPending(key))
        #expect(coordinator.revision(for: hostID) == 2)
    }
}
