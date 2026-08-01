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
        let store = RecordingTmuxSurfaceStore()
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
        #expect(!command.contains("status-style"))
    }

    @Test("new session launch reads the current terminal presentation style")
    func newSessionLaunchReadsCurrentPresentationStyle() async throws {
        let store = RecordingTmuxSurfaceStore()
        var style = TmuxPresentationStyle(
            foreground: "#3B4851",
            background: "#FFFFFF"
        )
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { .success("/opt/homebrew/bin/tmux") },
            presentationStyleProvider: { style }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "docbank",
            host: .local,
            launchMode: .create
        )
        style = TmuxPresentationStyle(
            foreground: "#EEEEEE",
            background: "#111111"
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains("fg=#EEEEEE,bg=#111111"))
        #expect(command.contains("status-style"))
        #expect(!command.contains("fg=#3B4851,bg=#FFFFFF"))
    }

    @Test("existing sessions keep their current presentation by default")
    func existingSessionKeepsCurrentPresentation() async throws {
        let store = RecordingTmuxSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { .success("/opt/homebrew/bin/tmux") },
            presentationStyleProvider: {
                TmuxPresentationStyle(
                    foreground: "#3B4851",
                    background: "#FFFFFF"
                )
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "existing",
            host: .local
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(!command.contains("window-style"))
        #expect(!command.contains("status-style"))
    }

    @Test("existing sessions accept the shared presentation opt-in")
    func existingSessionAcceptsPresentationOptIn() async throws {
        let store = RecordingTmuxSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { .success("/opt/homebrew/bin/tmux") },
            presentationStyleProvider: {
                TmuxPresentationStyle(
                    foreground: "#3B4851",
                    background: "#FFFFFF"
                )
            },
            appliesPresentationStyleToExistingSessionsProvider: { true }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "existing",
            host: .local
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains("fg=#3B4851,bg=#FFFFFF"))
        #expect(command.contains("status-style"))
    }

    @Test("isolated session socket participates in command routing")
    func isolatedSessionUsesReturnedSocket() async throws {
        let store = RecordingTmuxSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { .success("/usr/bin/tmux") },
            localKwtPathProvider: {
                "/Applications/Ghosthub.app/Contents/Helpers/kwt"
            },
            presentationStyleProvider: {
                TmuxPresentationStyle(
                    foreground: "#3B4851",
                    background: "#FFFFFF"
                )
            },
            appliesPresentationStyleToExistingSessionsProvider: { true }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "pr-32",
            host: .local,
            socketName: "kwt-pr-0123456789abcdef",
            workingDirectory: "/worktrees/pr-32"
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains(
            "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        ))
        #expect(command.contains("/worktrees/pr-32"))
        #expect(command.contains(#"'\''pr'\'' '\''attach'\''"#))
        #expect(command.contains("kwt-pr-0123456789abcdef"))
        #expect(!command.contains("'open'"))
    }

    @Test("ordinary worktree path attaches directly through kwt")
    func ordinaryWorktreeUsesKwtAttachment() async throws {
        let store = RecordingTmuxSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { .success("/usr/bin/tmux") },
            localKwtPathProvider: {
                "/Applications/Ghosthub.app/Contents/Helpers/kwt"
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "kwt-widget-feature",
            host: .local,
            workingDirectory: "/worktrees/widget",
            openWorkspace: true
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains("Helpers/kwt"))
        #expect(command.contains("open"))
        #expect(command.contains("/worktrees/widget"))
        #expect(!command.contains("--start-session"))
        #expect(!command.contains("attach-session"))
    }

    @Test("endpoint changes replace provisioning and active handles")
    func endpointChangesReplaceHandles() async throws {
        let store = RecordingTmuxSurfaceStore()
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
        let store = RecordingTmuxSurfaceStore(
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
            if case .disconnected = $0 {
                return true
            }
            return false
        })
        await waitUntilMainActor {
            states.contains {
                if case .disconnected = $0 {
                    return true
                }
                return false
            }
        }

        #expect(!states.contains(.connected))
        #expect(!coordinator.hasLaunched(handle))
        #expect(store.removedKeys.count == 1)
    }

    @Test("an exited tmux client records a closed attachment")
    func exitedClientClosesAttachment() async throws {
        let store = RecordingTmuxSurfaceStore()
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
            host: .local
        )
        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { states.contains(.connected) }

        let close = try #require(store.surface.closeObservers[handle.id])
        close(true)

        #expect(coordinator.hasClosedAttachment(handle))
        #expect(states.last == .disconnected(
            reason: "The tmux attachment to “release-work” closed."
        ))
    }
}

private enum SurfaceLaunchTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "Surface launch rejected" }
}
