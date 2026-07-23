import Foundation
import GhosthubTerminal
import GhosthubTmux
import GhosthubWorkspace

@MainActor
protocol TmuxPaneSurfacing: AnyObject {
    var blocksClipboardAccess: Bool { get set }
    var launchError: Error? { get }
    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool) -> Void
    )
}

extension TerminalSurfaceView: TmuxPaneSurfacing {
    var launchError: Error? { error }
}

@MainActor
protocol TmuxSurfaceStoring: AnyObject {
    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> TmuxPaneSurfacing?
    func removeSurface(for key: SurfaceKey)
}

extension TerminalSurfaceCoordinator: TmuxSurfaceStoring {
    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> TmuxPaneSurfacing? {
        surface(for: key, configuration: configuration)
    }
}

struct BorrowedTmuxSessionHandle: Equatable, Sendable {
    var id: UUID
    var hostID: UUID
    var name: String
    var surfaceID: UUID
}

private struct NativeTmuxSessionKey: Hashable {
    var hostID: UUID
    var name: String
}

private struct NativeTmuxAttachment {
    var host: TmuxHost
    var tmuxPath: String
    var launchMode: TmuxAttachmentLaunchMode
    var workingDirectory: String?
}

/// Hosts ordinary tmux clients for kwt workspaces and unbound sessions.
/// Tmux owns every window, pane, and byte of history; this coordinator owns
/// only binary resolution and the disposable local libghostty presentation.
@MainActor
final class NativeTmuxSessionCoordinator {
    private let terminalCoordinator: any TmuxSurfaceStoring
    private let tmuxPathProvider:
        @Sendable () -> Result<String, TmuxBinaryError>
    private let remoteTmuxPathProvider:
        @Sendable (SSHHostInfo) -> Result<String, TmuxBinaryError>
    private var handlesByKey: [NativeTmuxSessionKey: BorrowedTmuxSessionHandle] = [:]
    private var targetHostsByHandle: [UUID: TmuxHost] = [:]
    private var attachments: [UUID: NativeTmuxAttachment] = [:]
    private var endedHandles: Set<UUID> = []
    private var launchedHandles: Set<UUID> = []
    private var tmuxPathsByHost: [TmuxHost: String] = [:]
    private var provisioningHandles: Set<UUID> = []
    private var provisioningTasks: [UUID: Task<Void, Never>] = [:]
    private var isShuttingDown = false

    var onStateChanged: ((BorrowedTmuxSessionHandle, ConnectionState) -> Void)?
    var onSurfaceReady: ((BorrowedTmuxSessionHandle) -> Void)?

    init(
        terminalCoordinator: any TmuxSurfaceStoring,
        tmuxPathProvider: @escaping @Sendable () -> Result<String, TmuxBinaryError>,
        remoteTmuxPathProvider: @escaping @Sendable (SSHHostInfo)
            -> Result<String, TmuxBinaryError> = {
                TmuxBinaryResolver().resolveTmuxPath(on: $0)
            }
    ) {
        self.terminalCoordinator = terminalCoordinator
        self.tmuxPathProvider = tmuxPathProvider
        self.remoteTmuxPathProvider = remoteTmuxPathProvider
    }

    func attach(
        hostID: UUID,
        name: String,
        host: TmuxHost,
        launchMode: TmuxAttachmentLaunchMode = .attach,
        workingDirectory: String? = nil
    ) -> BorrowedTmuxSessionHandle {
        let key = NativeTmuxSessionKey(hostID: hostID, name: name)
        if let existing = handlesByKey[key],
           targetHostsByHandle[existing.id] != host {
            removeHandle(existing, for: key)
        }
        let handle = handlesByKey[key]
            ?? BorrowedTmuxSessionHandle(
                id: UUID(),
                hostID: hostID,
                name: name,
                surfaceID: UUID()
            )
        handlesByKey[key] = handle
        targetHostsByHandle[handle.id] = host
        endedHandles.remove(handle.id)

        guard !isShuttingDown,
              attachments[handle.id] == nil,
              !provisioningHandles.contains(handle.id)
        else { return handle }

        provisioningHandles.insert(handle.id)
        onStateChanged?(handle, .connecting)
        let cachedPath = tmuxPathsByHost[host]
        let tmuxPathProvider = tmuxPathProvider
        let remoteTmuxPathProvider = remoteTmuxPathProvider
        provisioningTasks[handle.id] = Task { [weak self] in
            let resolution: Result<String, TmuxBinaryError>
            if let cachedPath {
                resolution = .success(cachedPath)
            } else {
                let probe = Task.detached(priority: .userInitiated) {
                    switch host {
                    case .local:
                        return tmuxPathProvider()
                    case let .ssh(info):
                        return remoteTmuxPathProvider(info)
                    }
                }
                resolution = await withTaskCancellationHandler {
                    await probe.value
                } onCancel: {
                    probe.cancel()
                }
            }
            self?.finishAttach(
                handle: handle,
                host: host,
                launchMode: launchMode,
                workingDirectory: workingDirectory,
                resolution: resolution
            )
        }
        return handle
    }

    private func finishAttach(
        handle: BorrowedTmuxSessionHandle,
        host: TmuxHost,
        launchMode: TmuxAttachmentLaunchMode,
        workingDirectory: String?,
        resolution: Result<String, TmuxBinaryError>
    ) {
        provisioningTasks.removeValue(forKey: handle.id)
        provisioningHandles.remove(handle.id)
        let key = NativeTmuxSessionKey(hostID: handle.hostID, name: handle.name)
        guard handlesByKey[key] == handle,
              targetHostsByHandle[handle.id] == host,
              attachments[handle.id] == nil else { return }
        switch resolution {
        case let .success(path):
            tmuxPathsByHost[host] = path
            attachments[handle.id] = NativeTmuxAttachment(
                host: host,
                tmuxPath: path,
                launchMode: launchMode,
                workingDirectory: workingDirectory
            )
            onSurfaceReady?(handle)
        case let .failure(error):
            onStateChanged?(
                handle,
                .disconnected(reason: error.localizedDescription)
            )
        }
    }

    func detach(hostID: UUID, name: String) {
        let key = NativeTmuxSessionKey(hostID: hostID, name: name)
        guard let handle = handlesByKey.removeValue(forKey: key) else {
            return
        }
        removeHandle(handle, for: key, keyAlreadyRemoved: true)
    }

    @discardableResult
    func detachAll(hostID: UUID) -> [BorrowedTmuxSessionHandle] {
        let entries = handlesByKey.filter { $0.key.hostID == hostID }
        for (key, handle) in entries {
            removeHandle(handle, for: key)
        }
        return entries.map(\.value)
    }

    private func removeHandle(
        _ handle: BorrowedTmuxSessionHandle,
        for key: NativeTmuxSessionKey,
        keyAlreadyRemoved: Bool = false
    ) {
        if !keyAlreadyRemoved {
            handlesByKey.removeValue(forKey: key)
        }
        provisioningTasks.removeValue(forKey: handle.id)?.cancel()
        provisioningHandles.remove(handle.id)
        targetHostsByHandle.removeValue(forKey: handle.id)
        attachments.removeValue(forKey: handle.id)
        endedHandles.remove(handle.id)
        launchedHandles.remove(handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
    }

    func hasLaunched(_ handle: BorrowedTmuxSessionHandle) -> Bool {
        launchedHandles.contains(handle.id)
    }

    func surface(handle: BorrowedTmuxSessionHandle) -> TerminalSurfaceView? {
        guard !endedHandles.contains(handle.id),
              let attachment = attachments[handle.id]
        else { return nil }
        let info = TmuxAttachmentInfo(
            sessionName: handle.name,
            host: attachment.host,
            launchMode: attachment.launchMode
        )
        let surface = terminalCoordinator.paneSurface(
            for: surfaceKey(handle),
            configuration: TerminalSurfaceConfiguration(
                workingDirectory: NSHomeDirectory(),
                command: info.attachCommand(
                    tmuxPath: attachment.tmuxPath,
                    workingDirectory: attachment.workingDirectory
                )
            )
        )
        guard let surface else { return nil }
        if let error = surface.launchError {
            endedHandles.insert(handle.id)
            attachments.removeValue(forKey: handle.id)
            terminalCoordinator.removeSurface(for: surfaceKey(handle))
            reportSurfaceStateLater(
                handle,
                state: .disconnected(reason: error.localizedDescription)
            )
            return nil
        }
        surface.blocksClipboardAccess = attachment.host.isRemote
        surface.registerSurfaceCloseObserver(
            id: handle.id,
            onSurfaceClosed: { [weak self] _ in
                self?.surfaceDidClose(handle)
            }
        )
        if launchedHandles.insert(handle.id).inserted {
            reportSurfaceStateLater(
                handle,
                state: .connected,
                requiresLiveSurface: true
            )
        }
        return surface as? TerminalSurfaceView
    }

    private func reportSurfaceStateLater(
        _ handle: BorrowedTmuxSessionHandle,
        state: ConnectionState,
        requiresLiveSurface: Bool = false
    ) {
        Task { [weak self] in
            guard let self, !isShuttingDown else { return }
            let key = NativeTmuxSessionKey(
                hostID: handle.hostID,
                name: handle.name
            )
            guard handlesByKey[key] == handle else { return }
            if requiresLiveSurface {
                guard launchedHandles.contains(handle.id),
                      !endedHandles.contains(handle.id)
                else { return }
            }
            onStateChanged?(handle, state)
        }
    }

    private func surfaceDidClose(_ handle: BorrowedTmuxSessionHandle) {
        let key = NativeTmuxSessionKey(hostID: handle.hostID, name: handle.name)
        guard handlesByKey[key] == handle else { return }
        endedHandles.insert(handle.id)
        attachments.removeValue(forKey: handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
        onStateChanged?(
            handle,
            .disconnected(
                reason: "The tmux client exited. Retry to attach again."
            )
        )
    }

    func shutdown() {
        isShuttingDown = true
        let handles = Array(handlesByKey.values)
        provisioningTasks.values.forEach { $0.cancel() }
        provisioningTasks.removeAll()
        provisioningHandles.removeAll()
        handlesByKey.removeAll()
        targetHostsByHandle.removeAll()
        attachments.removeAll()
        endedHandles.removeAll()
        launchedHandles.removeAll()
        for handle in handles {
            terminalCoordinator.removeSurface(for: surfaceKey(handle))
        }
    }

    private func surfaceKey(_ handle: BorrowedTmuxSessionHandle) -> SurfaceKey {
        SurfaceKey(
            worktreeID: handle.id,
            hostID: handle.hostID,
            target: .tmuxSession,
            leafID: handle.surfaceID
        )
    }
}
