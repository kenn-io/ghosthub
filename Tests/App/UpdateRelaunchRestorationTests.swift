import Foundation
import Testing
@testable import GhosthubApp

@MainActor
@Suite("Update relaunch restoration")
struct UpdateRelaunchRestorationTests {
    @Test("replays every saved window and consumes the manifest")
    func replaysSavedWindows() throws {
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
        let defaultState = WorkspaceWindowState.fresh()
        #expect(
            restorer.stateForAppearance(presented: defaultState) == first
        )
        restorer.didBeginRestoring(windowID: first.windowID)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

        #expect(restorer.takeStatesToOpen() == [second])
        #expect(restorer.stateForAppearance(presented: second) == second)
        restorer.didBeginRestoring(windowID: second.windowID)

        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(restorer.takeStatesToOpen().isEmpty)
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

    @Test("matching native scenes do not open duplicate windows")
    func matchingNativeScenesAvoidDuplicates() throws {
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

        #expect(restorer.stateForAppearance(presented: first) == first)
        restorer.didBeginRestoring(windowID: first.windowID)
        #expect(restorer.takeStatesToOpen().isEmpty)

        #expect(restorer.stateForAppearance(presented: second) == second)
        restorer.didBeginRestoring(windowID: second.windowID)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
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
