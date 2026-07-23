import Foundation
import GhosthubTerminal
import GhosthubTmux
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Native tmux connection identity")
@MainActor
struct NativeTmuxSessionCoordinatorTests {
    @Test("new named sessions use tmux create-or-attach mode")
    func namedSessionUsesCreateMode() async throws {
        let store = TmuxSurfaceStoreStub()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { .success("/opt/homebrew/bin/tmux") }
        )
        var states: [ConnectionState] = []
        var readyHandles: [BorrowedTmuxSessionHandle] = []
        coordinator.onStateChanged = { _, state in states.append(state) }
        coordinator.onSurfaceReady = { readyHandles.append($0) }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "release-work",
            host: .local,
            launchMode: .create
        )

        #expect(coordinator.surface(handle: handle) == nil)
        #expect(store.requestedConfigurations.isEmpty)
        await waitUntilMainActor { readyHandles == [handle] }
        #expect(!states.contains(.connected))

        _ = coordinator.surface(handle: handle)
        #expect(!store.requestedConfigurations.isEmpty)
        #expect(!states.contains(.connected))

        await waitUntilMainActor { states.contains(.connected) }
        #expect(states.filter { $0 == .connected }.count == 1)
        _ = coordinator.surface(handle: handle)
        #expect(states.filter { $0 == .connected }.count == 1)

        let command = try #require(store.requestedConfigurations.last?.command)
        #expect(command.contains("new-session"))
        #expect(command.contains("'-A'"))
        #expect(command.contains("'-E'"))
        #expect(command.contains("release-work"))
        #expect(!command.contains("'-d'"))
        #expect(!command.contains("attach-session"))
        #expect(command.contains("status-style"))
    }

    @Test("endpoint changes replace provisioning and active handles")
    func endpointChangesReplaceHandles() async throws {
        let store = TmuxSurfaceStoreStub()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { .success("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _ in .success("/usr/bin/tmux") }
        )
        var states: [UUID: ConnectionState] = [:]
        coordinator.onStateChanged = { handle, state in
            states[handle.id] = state
        }
        let hostID = UUID()
        let first = coordinator.attach(
            hostID: hostID,
            name: "shared",
            host: .ssh(.init(
                user: "user",
                hostname: "old.example.com",
                port: nil
            ))
        )
        let second = coordinator.attach(
            hostID: hostID,
            name: "shared",
            host: .ssh(.init(
                user: "user",
                hostname: "new.example.com",
                port: nil
            ))
        )

        #expect(first.id != second.id)
        await waitUntilMainActor {
            _ = coordinator.surface(handle: second)
            return states[second.id] == .connected
        }
        let secondSurfaceKey = try #require(store.requestedKeys.last)

        let third = coordinator.attach(
            hostID: hostID,
            name: "shared",
            host: .ssh(.init(
                user: "user",
                hostname: "third.example.com",
                port: 2222
            ))
        )

        #expect(third.id != second.id)
        #expect(store.removedKeys.last == secondSurfaceKey)
        let requestCount = store.requestedKeys.count
        _ = coordinator.surface(handle: second)
        #expect(store.requestedKeys.count == requestCount)
    }

    @Test("rejected terminal surfaces never report command launch")
    func rejectedSurfaceDoesNotLaunch() async {
        let store = TmuxSurfaceStoreStub(
            launchError: SurfaceLaunchTestError.rejected
        )
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { .success("/usr/bin/tmux") }
        )
        var states: [ConnectionState] = []
        var isSurfaceReady = false
        coordinator.onStateChanged = { _, state in states.append(state) }
        coordinator.onSurfaceReady = { _ in isSurfaceReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "release-work",
            host: .local,
            launchMode: .create
        )

        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)
        #expect(!states.contains {
            if case .disconnected = $0 { return true }
            return false
        })
        await waitUntilMainActor {
            states.contains {
                if case .disconnected = $0 { return true }
                return false
            }
        }

        #expect(!states.contains(.connected))
        #expect(!coordinator.hasLaunched(handle))
        #expect(store.removedKeys.count == 1)
    }
}

private enum SurfaceLaunchTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "Surface launch rejected" }
}

@MainActor
private final class TmuxPaneSurfaceStub: TmuxPaneSurfacing {
    var blocksClipboardAccess = false
    let launchError: Error?
    private(set) var closeObservers: [UUID: (Bool) -> Void] = [:]

    init(launchError: Error? = nil) {
        self.launchError = launchError
    }

    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool) -> Void
    ) {
        closeObservers[id] = onSurfaceClosed
    }
}

@MainActor
private final class TmuxSurfaceStoreStub: TmuxSurfaceStoring {
    private let surface: TmuxPaneSurfaceStub
    private(set) var requestedKeys: [SurfaceKey] = []
    private(set) var requestedConfigurations: [TerminalSurfaceConfiguration] = []
    private(set) var removedKeys: [SurfaceKey] = []

    init(launchError: Error? = nil) {
        surface = TmuxPaneSurfaceStub(launchError: launchError)
    }

    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> (any TmuxPaneSurfacing)? {
        requestedKeys.append(key)
        requestedConfigurations.append(configuration)
        return surface
    }

    func removeSurface(for key: SurfaceKey) {
        removedKeys.append(key)
    }
}
