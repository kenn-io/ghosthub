import Foundation
import Testing
@testable import GhosthubApp

@MainActor
@Suite("Update relaunch restoration")
struct UpdateRelaunchRestorationTests {
    @Test("missing native scenes are assigned before new windows open")
    func replaysMissingNativeScenes() throws {
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
        restorer.nativeWindowRestorationDidFinish(
            expectedSceneCount: 1
        )

        #expect(restored == [first])
        #expect(opened == [second])
        restorer.didBeginRestoring(windowID: first.windowID)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

        #expect(
            restorer.registerScene(
                id: UUID(),
                presented: second,
                restore: { restored.append($0) },
                openWindow: { opened.append($0) }
            ) == .restore(second)
        )
        restorer.didBeginRestoring(windowID: second.windowID)

        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
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
        var restored: [WorkspaceWindowState] = []
        var opened: [WorkspaceWindowState] = []

        #expect(
            restorer.registerScene(
                id: firstSceneID,
                presented: nil,
                restore: { restored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        #expect(
            restorer.registerScene(
                id: secondSceneID,
                presented: nil,
                restore: { restored.append($0) },
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

        #expect(restored.isEmpty)
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

        #expect(opened == [second])
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("native values arriving after reconciliation do not duplicate windows")
    func nativeValuesArriveAfterReconciliationBegins() throws {
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
        var restored: [WorkspaceWindowState] = []
        var opened: [WorkspaceWindowState] = []

        #expect(
            restorer.registerScene(
                id: firstSceneID,
                presented: nil,
                restore: { restored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        #expect(
            restorer.registerScene(
                id: secondSceneID,
                presented: nil,
                restore: { restored.append($0) },
                openWindow: { opened.append($0) }
            ) == .waitingForNativeRestoration
        )
        restorer.nativeWindowRestorationDidFinish(
            expectedSceneCount: 2
        )

        #expect(restored == [first, second])
        #expect(opened.isEmpty)
        #expect(
            restorer.receivePresentedState(
                sceneID: firstSceneID,
                presented: first
            ) == .ordinary
        )
        #expect(
            restorer.receivePresentedState(
                sceneID: secondSceneID,
                presented: second
            ) == .ordinary
        )
        #expect(opened.isEmpty)
    }

    @Test("native completion waits for every restored scene to register")
    func completionPrecedesMatchingSceneRegistration() throws {
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

        restorer.nativeWindowRestorationDidFinish(
            expectedSceneCount: 2
        )
        #expect(
            restorer.registerScene(
                id: UUID(),
                presented: first,
                restore: { _ in },
                openWindow: { opened.append($0) }
            ) == .restore(first)
        )
        restorer.didBeginRestoring(windowID: first.windowID)
        restorer.reconcileIfNativeRestorationFinished()
        #expect(opened.isEmpty)

        #expect(
            restorer.registerScene(
                id: UUID(),
                presented: second,
                restore: { _ in },
                openWindow: { opened.append($0) }
            ) == .restore(second)
        )
        restorer.didBeginRestoring(windowID: second.windowID)
        restorer.reconcileIfNativeRestorationFinished()

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
