import Foundation
import Testing
@testable import GhosthubApp

@MainActor
@Suite("Update relaunch restoration")
struct UpdateRelaunchRestorationTests {
    @Test("zero native windows restore a temporarily nil relaunch scene")
    func zeroNativeWindowsRestoreNilRelaunchScene() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = UpdateRelaunchManifestStore(
            fileURL: scratch.appendingPathComponent("relaunch.json")
        )
        let first = state(
            sessionName: "editor",
            socketName: nil,
            owner: .unbound
        )
        let second = state(
            sessionName: "kwt-ghosthub-fix",
            socketName: "kwt-0123456789abcdef",
            owner: .worktree(
                generation: "0123456789abcdef0123456789abcdef"
            )
        )
        try store.save([first, second])

        let restorer = UpdateRelaunchRestorer(store: store)
        let defaultSceneID = UUID()
        var restored: [WorkspaceWindowState] = []
        var opened: [WorkspaceWindowState] = []
        #expect(
            restorer.registerScene(
                id: defaultSceneID,
                presented: nil,
                restore: { restored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        #expect(
            !restorer.nativeWindowRestorationDidFinish(
                expectedSceneCount: 0
            )
        )
        restorer.reconcileAfterSceneBindingsSettled()

        #expect(restored == [first])
        #expect(opened.count == 1)
        let replayRequest = try #require(opened.first)
        #expect(replayRequest.navigation == nil)
        #expect(replayRequest.tmux == nil)
        #expect(replayRequest.windowID != second.windowID)
        restorer.didBeginRestoring(windowID: first.windowID)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

        #expect(
            restorer.registerScene(
                id: UUID(),
                presented: replayRequest,
                restore: { restored.append($0) },
                openWindow: { opened.append($0) }
            ) == .restore(second)
        )
        restorer.didBeginRestoring(windowID: second.windowID)

        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("zero native windows without relaunch state need a fresh window")
    func zeroNativeWindowsNeedFreshWindow() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let restorer = UpdateRelaunchRestorer(
            store: UpdateRelaunchManifestStore(
                fileURL: scratch.appendingPathComponent("relaunch.json")
            )
        )

        #expect(
            restorer.nativeWindowRestorationDidFinish(
                expectedSceneCount: 0
            )
        )
    }

    @Test("an aborted relaunch manifest can be discarded")
    func discardsAbortedRelaunch() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = UpdateRelaunchManifestStore(
            fileURL: scratch.appendingPathComponent("relaunch.json")
        )
        try store.save([
            state(
                sessionName: "editor",
                socketName: nil,
                owner: .unbound
            ),
        ])

        try store.clear()

        #expect(try store.load() == nil)
    }

    @Test("late native values claim initially nil scenes without duplicates")
    func lateNativeValuesClaimNilScenes() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = UpdateRelaunchManifestStore(
            fileURL: scratch.appendingPathComponent("relaunch.json")
        )
        let first = state(
            sessionName: "editor",
            socketName: nil,
            owner: .unbound
        )
        let second = state(
            sessionName: "review",
            socketName: nil,
            owner: .unbound
        )
        try store.save([first, second])
        let restorer = UpdateRelaunchRestorer(store: store)
        let firstSceneID = UUID()
        let secondSceneID = UUID()
        var firstRestored: [WorkspaceWindowState] = []
        var secondRestored: [WorkspaceWindowState] = []
        var opened: [WorkspaceWindowState] = []

        #expect(
            restorer.registerScene(
                id: firstSceneID,
                presented: nil,
                restore: { firstRestored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        #expect(
            restorer.registerScene(
                id: secondSceneID,
                presented: nil,
                restore: { secondRestored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )

        #expect(
            restorer.receivePresentedState(
                sceneID: firstSceneID,
                presented: first
            ) == .restore(first)
        )
        restorer.didBeginRestoring(windowID: first.windowID)
        #expect(
            restorer.receivePresentedState(
                sceneID: secondSceneID,
                presented: second
            ) == .restore(second)
        )
        restorer.didBeginRestoring(windowID: second.windowID)
        restorer.nativeWindowRestorationDidFinish(
            expectedSceneCount: 2
        )

        #expect(firstRestored.isEmpty)
        #expect(secondRestored.isEmpty)
        #expect(opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("partial native restoration opens every unclaimed saved window")
    func partialNativeRestorationOpensMissingWindows() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = UpdateRelaunchManifestStore(
            fileURL: scratch.appendingPathComponent("relaunch.json")
        )
        let first = state(
            sessionName: "editor",
            socketName: nil,
            owner: .unbound
        )
        let second = state(
            sessionName: "review",
            socketName: nil,
            owner: .unbound
        )
        try store.save([first, second])
        let restorer = UpdateRelaunchRestorer(store: store)
        var opened: [WorkspaceWindowState] = []

        #expect(
            restorer.registerScene(
                id: UUID(),
                presented: first,
                restore: { _ in },
                openWindow: { opened.append($0) }
            ) == .restore(first)
        )
        restorer.didBeginRestoring(windowID: first.windowID)
        restorer.nativeWindowRestorationDidFinish(
            expectedSceneCount: 1
        )
        restorer.reconcileAfterSceneBindingsSettled()

        #expect(opened.count == 1)
        #expect(opened.first?.navigation == nil)
        #expect(opened.first?.tmux == nil)
        #expect(opened.first?.windowID != second.windowID)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("late native IDs reclaim scheduled replacement windows")
    func lateNativeIDReclaimsScheduledWindow() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = UpdateRelaunchManifestStore(
            fileURL: scratch.appendingPathComponent("relaunch.json")
        )
        let first = state(
            sessionName: "editor",
            socketName: nil,
            owner: .unbound
        )
        let second = state(
            sessionName: "review",
            socketName: nil,
            owner: .unbound
        )
        try store.save([first, second])
        let restorer = UpdateRelaunchRestorer(store: store)
        let nativeSceneID = UUID()
        var nativeRestored: [WorkspaceWindowState] = []
        var replayRestored: [WorkspaceWindowState] = []
        var opened: [WorkspaceWindowState] = []

        #expect(
            restorer.registerScene(
                id: nativeSceneID,
                presented: nil,
                restore: { nativeRestored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        restorer.nativeWindowRestorationDidFinish(expectedSceneCount: 1)
        restorer.reconcileAfterSceneBindingsSettled()

        #expect(nativeRestored == [first])
        let replayRequest = try #require(opened.first)
        restorer.didBeginRestoring(windowID: first.windowID)

        let replayObservation = restorer.registerScene(
            id: UUID(),
            presented: replayRequest,
            restore: { replayRestored.append($0) },
            openWindow: { opened.append($0) }
        )
        #expect(replayObservation == .restore(second))
        if case let .restore(state) = replayObservation {
            replayRestored.append(state)
            restorer.didBeginRestoring(windowID: state.windowID)
        }

        let nativeObservation = restorer.receivePresentedState(
            sceneID: nativeSceneID,
            presented: second
        )
        #expect(nativeObservation == .restore(second))
        if case let .restore(state) = nativeObservation {
            nativeRestored.append(state)
        }

        #expect(nativeRestored.last == second)
        #expect(replayRestored.last == first)
        #expect(opened == [replayRequest])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("a displaced window stays pending until its replay scene is live")
    func displacedWindowWaitsForReplayScene() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = UpdateRelaunchManifestStore(
            fileURL: scratch.appendingPathComponent("relaunch.json")
        )
        let first = state(
            sessionName: "editor",
            socketName: nil,
            owner: .unbound
        )
        let second = state(
            sessionName: "review",
            socketName: nil,
            owner: .unbound
        )
        try store.save([first, second])
        let restorer = UpdateRelaunchRestorer(store: store)
        let nativeSceneID = UUID()
        var nativeRestored: [WorkspaceWindowState] = []
        var opened: [WorkspaceWindowState] = []

        #expect(
            restorer.registerScene(
                id: nativeSceneID,
                presented: nil,
                restore: { nativeRestored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        restorer.nativeWindowRestorationDidFinish(expectedSceneCount: 1)
        restorer.reconcileAfterSceneBindingsSettled()
        let replayRequest = try #require(opened.first)
        restorer.didBeginRestoring(windowID: first.windowID)

        let nativeObservation = restorer.receivePresentedState(
            sceneID: nativeSceneID,
            presented: second
        )
        #expect(nativeObservation == .restore(second))
        if case let .restore(state) = nativeObservation {
            nativeRestored.append(state)
            restorer.didBeginRestoring(windowID: state.windowID)
        }

        #expect(opened == [replayRequest, replayRequest])
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

        let replayObservation = restorer.registerScene(
            id: UUID(),
            presented: replayRequest,
            restore: { _ in },
            openWindow: { opened.append($0) }
        )
        #expect(replayObservation == .restore(first))
        restorer.didBeginRestoring(windowID: first.windowID)

        #expect(nativeRestored.last == second)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("late reversed native values correct provisional fallback assignments")
    func reversedNativeValuesCorrectFallbackAssignments() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = UpdateRelaunchManifestStore(
            fileURL: scratch.appendingPathComponent("relaunch.json")
        )
        let first = state(
            sessionName: "editor",
            socketName: nil,
            owner: .unbound
        )
        let second = state(
            sessionName: "review",
            socketName: nil,
            owner: .unbound
        )
        try store.save([first, second])
        let restorer = UpdateRelaunchRestorer(store: store)
        let firstSceneID = UUID()
        let secondSceneID = UUID()
        var firstRestored: [WorkspaceWindowState] = []
        var secondRestored: [WorkspaceWindowState] = []
        var opened: [WorkspaceWindowState] = []

        #expect(
            restorer.registerScene(
                id: firstSceneID,
                presented: nil,
                restore: { firstRestored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        #expect(
            restorer.registerScene(
                id: secondSceneID,
                presented: nil,
                restore: { secondRestored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        restorer.nativeWindowRestorationDidFinish(
            expectedSceneCount: 2
        )
        restorer.reconcileAfterSceneBindingsSettled()

        #expect(firstRestored == [first])
        #expect(secondRestored == [second])
        #expect(opened.isEmpty)
        let secondObservation = restorer.receivePresentedState(
            sceneID: secondSceneID,
            presented: first
        )
        #expect(secondObservation == .restore(first))
        if case let .restore(state) = secondObservation {
            secondRestored.append(state)
        }
        #expect(
            restorer.receivePresentedState(
                sceneID: firstSceneID,
                presented: second
            ) == .ordinary
        )
        #expect(firstRestored.last == second)
        #expect(secondRestored.last == first)
        #expect(opened.isEmpty)
    }

    @Test("late native IDs preserve their restored window association")
    func completionPrecedesReverseNativeIDs() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = UpdateRelaunchManifestStore(
            fileURL: scratch.appendingPathComponent("relaunch.json")
        )
        let first = state(
            sessionName: "editor",
            socketName: nil,
            owner: .unbound
        )
        let second = state(
            sessionName: "review",
            socketName: nil,
            owner: .unbound
        )
        try store.save([first, second])
        let restorer = UpdateRelaunchRestorer(store: store)
        let firstSceneID = UUID()
        let secondSceneID = UUID()
        var firstRestored: [WorkspaceWindowState] = []
        var secondRestored: [WorkspaceWindowState] = []
        var opened: [WorkspaceWindowState] = []

        restorer.nativeWindowRestorationDidFinish(
            expectedSceneCount: 2
        )
        #expect(
            restorer.registerScene(
                id: firstSceneID,
                presented: nil,
                restore: { firstRestored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        restorer.reconcileIfNativeRestorationFinished()
        #expect(opened.isEmpty)

        #expect(
            restorer.registerScene(
                id: secondSceneID,
                presented: nil,
                restore: { secondRestored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        restorer.reconcileIfNativeRestorationFinished()
        #expect(firstRestored.isEmpty)
        #expect(secondRestored.isEmpty)
        #expect(opened.isEmpty)

        for _ in 0 ..< 3 {
            await Task.yield()
        }

        let secondObservation = restorer.receivePresentedState(
            sceneID: secondSceneID,
            presented: first
        )
        #expect(secondObservation == .restore(first))
        if case let .restore(state) = secondObservation {
            secondRestored.append(state)
        }
        restorer.didBeginRestoring(windowID: first.windowID)
        let firstObservation = restorer.receivePresentedState(
            sceneID: firstSceneID,
            presented: second
        )
        #expect(firstObservation != .waitingForNativeRestoration)
        if case let .restore(state) = firstObservation {
            firstRestored.append(state)
        }
        restorer.didBeginRestoring(windowID: second.windowID)
        restorer.reconcileAfterSceneBindingsSettled()

        #expect(firstRestored.last == second)
        #expect(secondRestored.last == first)
        #expect(opened.isEmpty)
    }

    private func state(
        sessionName: String,
        socketName: String?,
        owner: WorkspaceTmuxOwnerDescriptor
    ) -> WorkspaceWindowState {
        let generation: String? = switch owner {
        case .unbound:
            nil
        case let .worktree(generation):
            generation
        }
        return WorkspaceWindowState(
            windowID: UUID(),
            navigation: WorkspaceNavigationDescriptor(
                hostKey: "local",
                projectKey: generation == nil
                    ? nil : "github.com/kenn-io/ghosthub",
                worktreeGeneration: generation
            ),
            tmux: WorkspaceTmuxDescriptor(
                hostKey: "local",
                sessionName: sessionName,
                socketName: socketName,
                owner: owner
            )
        )
    }
}
