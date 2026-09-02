import Foundation
import GhosthubTerminal
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubApp

enum WorkspaceTmuxTestSupport {
    static let probeNonce = "TEST-NONCE"

    static func previewPaneSplitter(
        identity: TmuxSessionIdentity
    ) -> TmuxPaneSplitter {
        TmuxPaneSplitter { _, _, command in
            guard command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY")
            else { return (0, "") }
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                    + "\t\(identity.serverPID)\t789\t321"
                    + "\t/dev/ttys001\t\(identity.sessionID)"
                    + "\t\(identity.createdAt)\t%9\n"
            )
        }
    }

    static func inventory(
        project: ProjectSummary,
        worktrees: [WorktreeSummary]
    ) -> KwtHostInventory {
        KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: project.rootPath,
                    lastTouched: nil,
                    registrationFingerprint:
                    project.registrationFingerprint
                ),
                worktrees: worktrees.map { worktree in
                    KwtWorktreeRecord(
                        path: worktree.path,
                        branch: worktree.branch,
                        commitHash: "",
                        isMain: worktree.isPrimary,
                        createdAt: worktree.createdAt,
                        generation: worktree.generation,
                        repository: project.scopedKey,
                        sessionName: worktree.tmuxSessionName ?? "",
                        tmuxSocketName: worktree.tmuxSocketName,
                        tmuxAttachMode: worktree.tmuxAttachMode
                    )
                },
                warning: nil
            ),
        ])
    }

    static func probeOutput(
        _ lines: [String],
        startupOutput: String? = nil
    ) -> String {
        ([startupOutput].compactMap { $0 }
            + ["GHOSTHUB_SSH_PROBE_\(probeNonce)_START"]
            + lines
            + ["GHOSTHUB_SSH_PROBE_\(probeNonce)_END", ""])
            .joined(separator: "\n")
    }
}

@MainActor
func launchActiveTmuxSurface(
    _ model: WorkspaceSceneModel,
    store: SceneTmuxSurfaceStoreStub
) async {
    await waitUntilMainActor(timeout: .seconds(15)) {
        model.prepareActiveBorrowedTmuxSurface()
        return store.requestCount > 0
            && !store.surface.closeObservers.isEmpty
    }
}

@MainActor
struct SceneModelRootHarness: View {
    @ObservedObject var model: WorkspaceSceneModel
    let onOpenTmuxSession: (WorkspaceTmuxSessionSelection) -> Void
    @State private var selection: WorkspaceSelection

    init(
        model: WorkspaceSceneModel,
        onOpenTmuxSession: @escaping (
            WorkspaceTmuxSessionSelection
        ) -> Void = { _ in }
    ) {
        self.model = model
        self.onOpenTmuxSession = onOpenTmuxSession
        _selection = State(initialValue: model.selection)
    }

    var body: some View {
        RootView(
            display: WorkspaceDisplayState(
                snapshot: model.snapshot,
                suppressesAutomaticWorktreeSessionOpen:
                model.suppressesSelectedWorktreeSessionOpen,
                activeTmuxSession: model.activeBorrowedTmuxSelection,
                activeTmuxSessionIsConnected:
                model.activeBorrowedTmuxSessionIsConnected
            ),
            handlers: InteractionHandlers(
                openTmuxSession: onOpenTmuxSession
            ),
            selection: $selection
        )
    }
}

@MainActor
final class SceneTmuxPaneSurfaceStub: NativeSessionPaneSurfacing {
    var blocksClipboardReads = false
    var launchError: Error?
    var launchFailureIsRetryable = false
    var childExitCode: UInt32?
    private(set) var closeObservers: [UUID: (Bool, UInt32?) -> Void] = [:]
    private(set) var lastObserverID: UUID?
    private(set) var previewGridSizes: [TmuxGridSize] = []
    private(set) var clearPreviewGridCount = 0

    @discardableResult
    func sizeForPreviewGrid(columns: Int, rows: Int) -> Bool {
        previewGridSizes.append(TmuxGridSize(columns: columns, rows: rows))
        return true
    }

    func clearPreviewGridSize() {
        clearPreviewGridCount += 1
    }

    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool, UInt32?) -> Void
    ) {
        closeObservers[id] = onSurfaceClosed
        lastObserverID = id
    }
}

enum SceneSurfaceLaunchError: LocalizedError {
    case rejected

    var errorDescription: String? {
        "The terminal rejected the replacement surface."
    }
}

@MainActor
final class SceneTmuxSurfaceStoreStub: NativeSessionSurfaceStoring {
    let surface = SceneTmuxPaneSurfaceStub()
    var returnsSurface = true
    private(set) var requestCount = 0
    private(set) var lastConfiguration: TerminalSurfaceConfiguration?
    private(set) var requestedKeys: [SurfaceKey] = []
    private(set) var removedKeys: [SurfaceKey] = []
    private var retainedKeys: Set<SurfaceKey> = []

    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> (any NativeSessionPaneSurfacing)? {
        guard !retainedKeys.contains(key) else { return surface }
        retainedKeys.insert(key)
        requestCount += 1
        lastConfiguration = configuration
        requestedKeys.append(key)
        return returnsSurface ? surface : nil
    }

    func paneSurfaceIfPresent(
        for key: SurfaceKey
    ) -> (any NativeSessionPaneSurfacing)? {
        retainedKeys.contains(key) ? surface : nil
    }

    func removeSurface(for key: SurfaceKey) {
        retainedKeys.remove(key)
        removedKeys.append(key)
    }
}

final class TmuxDiscoveryResultQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values:
        [Result<[DiscoveredTmuxSession], TmuxBinaryError>]
    private var removalCount = 0

    init(_ values: [Result<[DiscoveredTmuxSession], TmuxBinaryError>]) {
        self.values = values
    }

    func removeFirst()
        -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        lock.withLock {
            removalCount += 1
            return values.removeFirst()
        }
    }

    var count: Int {
        lock.withLock { removalCount }
    }
}

final class TmuxExactProbeResultQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<Bool, TmuxBinaryError>]
    private var removalCount = 0

    init(_ values: [Result<Bool, TmuxBinaryError>]) {
        self.values = values
    }

    func removeFirst() -> Result<Bool, TmuxBinaryError> {
        lock.withLock {
            removalCount += 1
            return values.removeFirst()
        }
    }

    var count: Int {
        lock.withLock { removalCount }
    }
}
