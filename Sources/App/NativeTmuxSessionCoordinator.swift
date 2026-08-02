import Foundation
import GhosthubTerminal
import GhosthubTmux
import GhosthubWorkspace

@MainActor
protocol TmuxPaneSurfacing: AnyObject {
    var blocksClipboardReads: Bool { get set }
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
    func surfaceIdentity(for key: SurfaceKey) -> UInt?
    func removeSurface(for key: SurfaceKey)
}

extension TmuxSurfaceStoring {
    func surfaceIdentity(for _: SurfaceKey) -> UInt? {
        nil
    }
}

extension TerminalSurfaceCoordinator: TmuxSurfaceStoring {
    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> TmuxPaneSurfacing? {
        surface(for: key, configuration: configuration)
    }

    func surfaceIdentity(for key: SurfaceKey) -> UInt? {
        surfaceIfPresent(for: key)?.surfaceIdentity
    }
}

struct BorrowedTmuxSessionHandle: Equatable, Sendable {
    var id: UUID
    var hostID: UUID
    var name: String
    var surfaceID: UUID
    var socketName: String?

    init(
        id: UUID,
        hostID: UUID,
        name: String,
        surfaceID: UUID,
        socketName: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.name = name
        self.surfaceID = surfaceID
        self.socketName = socketName
    }
}

private struct NativeTmuxSessionKey: Hashable {
    var hostID: UUID
    var name: String
    var socketName: String?
}

private struct NativeTmuxAttachment {
    var host: TmuxHost
    var tmuxPath: String
    var kwtPath: String?
    var remoteKwtCommandPrelude: String?
    var windowsKwtRelativePath: String?
    var socketName: String?
    var protectedWorkspacePath: String?
    var launchMode: TmuxAttachmentLaunchMode
    var workingDirectory: String?
    var openWorkspace: Bool
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
    private let localKwtPathProvider: @Sendable () -> String?
    private let remoteKwtCommandPreludeProvider: @Sendable () -> String?
    private let windowsKwtRelativePathProvider: @Sendable () -> String?
    private let presentationStyleProvider: () -> TmuxPresentationStyle?
    private let appliesPresentationStyleToExistingSessionsProvider:
        () -> Bool
    private var handlesByKey: [NativeTmuxSessionKey: BorrowedTmuxSessionHandle] = [:]
    private var targetHostsByHandle: [UUID: TmuxHost] = [:]
    private var attachments: [UUID: NativeTmuxAttachment] = [:]
    private var closedAttachmentHandles: Set<UUID> = []
    private var launchedHandles: Set<UUID> = []
    private var tmuxPathsByHost: [TmuxHost: String] = [:]
    private var provisioningHandles: Set<UUID> = []
    private var provisioningTasks: [UUID: Task<Void, Never>] = [:]
    private var deferredPresentationStyleHandles: Set<UUID> = []
    private var isShuttingDown = false

    var onStateChanged: ((BorrowedTmuxSessionHandle, ConnectionState) -> Void)?
    var onSurfaceReady: ((BorrowedTmuxSessionHandle) -> Void)?

    init(
        terminalCoordinator: any TmuxSurfaceStoring,
        tmuxPathProvider: @escaping @Sendable () -> Result<String, TmuxBinaryError>,
        localKwtPathProvider: @escaping @Sendable () -> String? = {
            KwtBinaryLocator.bundledPath()
        },
        remoteKwtCommandPreludeProvider:
        @escaping @Sendable () -> String? = {
            KwtBinaryLocator.remoteCommandPrelude(
                revision: KwtBinaryLocator.bundledRemoteRevision()
            )
        },
        windowsKwtRelativePathProvider:
        @escaping @Sendable () -> String? = {
            KwtBinaryLocator.windowsRemoteManagedRelativePath(
                revision: KwtBinaryLocator.bundledRemoteRevision()
            )
        },
        presentationStyleProvider:
        @escaping () -> TmuxPresentationStyle? = { nil },
        appliesPresentationStyleToExistingSessionsProvider:
        @escaping () -> Bool = { false },
        remoteTmuxPathProvider: @escaping @Sendable (SSHHostInfo)
            -> Result<String, TmuxBinaryError> = {
                TmuxBinaryResolver().resolveTmuxPath(on: $0)
            }
    ) {
        self.terminalCoordinator = terminalCoordinator
        self.tmuxPathProvider = tmuxPathProvider
        self.localKwtPathProvider = localKwtPathProvider
        self.remoteKwtCommandPreludeProvider =
            remoteKwtCommandPreludeProvider
        self.windowsKwtRelativePathProvider =
            windowsKwtRelativePathProvider
        self.presentationStyleProvider = presentationStyleProvider
        self.appliesPresentationStyleToExistingSessionsProvider =
            appliesPresentationStyleToExistingSessionsProvider
        self.remoteTmuxPathProvider = remoteTmuxPathProvider
    }

    func attach(
        hostID: UUID,
        name: String,
        host: TmuxHost,
        socketName: String? = nil,
        launchMode: TmuxAttachmentLaunchMode = .attach,
        workingDirectory: String? = nil,
        openWorkspace: Bool = false
    ) -> BorrowedTmuxSessionHandle {
        let key = NativeTmuxSessionKey(
            hostID: hostID,
            name: name,
            socketName: socketName
        )
        if let existing = handlesByKey[key],
           targetHostsByHandle[existing.id] != host {
            removeHandle(existing, for: key)
        }
        let handle = handlesByKey[key]
            ?? BorrowedTmuxSessionHandle(
                id: UUID(),
                hostID: hostID,
                name: name,
                surfaceID: UUID(),
                socketName: socketName
            )
        handlesByKey[key] = handle
        targetHostsByHandle[handle.id] = host
        closedAttachmentHandles.remove(handle.id)

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
                socketName: socketName,
                launchMode: launchMode,
                workingDirectory: workingDirectory,
                openWorkspace: openWorkspace,
                resolution: resolution
            )
        }
        return handle
    }

    private func finishAttach(
        handle: BorrowedTmuxSessionHandle,
        host: TmuxHost,
        socketName: String?,
        launchMode: TmuxAttachmentLaunchMode,
        workingDirectory: String?,
        openWorkspace: Bool,
        resolution: Result<String, TmuxBinaryError>
    ) {
        provisioningTasks.removeValue(forKey: handle.id)
        provisioningHandles.remove(handle.id)
        let key = sessionKey(handle)
        guard handlesByKey[key] == handle,
              targetHostsByHandle[handle.id] == host,
              attachments[handle.id] == nil else { return }
        switch resolution {
        case let .success(path):
            tmuxPathsByHost[host] = path
            let protectedWorkspacePath = socketName == nil
                ? nil
                : workingDirectory
            attachments[handle.id] = NativeTmuxAttachment(
                host: host,
                tmuxPath: path,
                kwtPath: host.isRemote ? nil : localKwtPathProvider(),
                remoteKwtCommandPrelude: host.isRemote
                    ? remoteKwtCommandPreludeProvider()
                    : nil,
                windowsKwtRelativePath: host.isRemote
                    ? windowsKwtRelativePathProvider()
                    : nil,
                socketName: socketName,
                protectedWorkspacePath: protectedWorkspacePath,
                launchMode: launchMode,
                workingDirectory: workingDirectory,
                openWorkspace: openWorkspace
            )
            onSurfaceReady?(handle)
        case let .failure(error):
            onStateChanged?(
                handle,
                .disconnected(reason: error.localizedDescription)
            )
        }
    }

    func detach(hostID: UUID, name: String, socketName: String? = nil) {
        let key = NativeTmuxSessionKey(
            hostID: hostID,
            name: name,
            socketName: socketName
        )
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
        closedAttachmentHandles.remove(handle.id)
        launchedHandles.remove(handle.id)
        deferredPresentationStyleHandles.remove(handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
    }

    func hasLaunched(_ handle: BorrowedTmuxSessionHandle) -> Bool {
        launchedHandles.contains(handle.id)
    }

    func hasClosedAttachment(_ handle: BorrowedTmuxSessionHandle) -> Bool {
        closedAttachmentHandles.contains(handle.id)
    }

    func hasDeferredPresentationStyle(
        _ handle: BorrowedTmuxSessionHandle
    ) -> Bool {
        deferredPresentationStyleHandles.contains(handle.id)
    }

    func shouldApplyPresentationStyle(
        _ handle: BorrowedTmuxSessionHandle
    ) -> Bool {
        guard let attachment = attachments[handle.id] else { return false }
        return attachment.launchMode == .create
            || appliesPresentationStyleToExistingSessionsProvider()
    }

    func markDeferredPresentationStyleApplied(
        _ handle: BorrowedTmuxSessionHandle
    ) {
        deferredPresentationStyleHandles.remove(handle.id)
    }

    func surface(handle: BorrowedTmuxSessionHandle) -> TerminalSurfaceView? {
        guard !closedAttachmentHandles.contains(handle.id),
              let attachment = attachments[handle.id]
        else { return nil }
        let appliesPresentationStyle =
            attachment.launchMode == .create
                || appliesPresentationStyleToExistingSessionsProvider()
        let presentationStyle = appliesPresentationStyle
            ? presentationStyleProvider()
            : nil
        let isFirstLaunch = !launchedHandles.contains(handle.id)
        let info = TmuxAttachmentInfo(
            sessionName: handle.name,
            host: attachment.host,
            socketName: attachment.socketName,
            workspacePath: attachment.openWorkspace
                ? attachment.workingDirectory
                : nil,
            protectedWorkspacePath: attachment.protectedWorkspacePath,
            presentationStyle: presentationStyle,
            launchMode: attachment.launchMode
        )
        let surface = terminalCoordinator.paneSurface(
            for: surfaceKey(handle),
            configuration: TerminalSurfaceConfiguration(
                workingDirectory: NSHomeDirectory(),
                command: info.attachCommand(
                    tmuxPath: attachment.tmuxPath,
                    kwtPath: attachment.kwtPath,
                    remoteKwtCommandPrelude:
                    attachment.remoteKwtCommandPrelude,
                    windowsKwtRelativePath:
                    attachment.windowsKwtRelativePath,
                    workingDirectory: attachment.workingDirectory
                )
            )
        )
        guard let surface else {
            deferredPresentationStyleHandles.remove(handle.id)
            return nil
        }
        if let error = surface.launchError {
            closedAttachmentHandles.insert(handle.id)
            attachments.removeValue(forKey: handle.id)
            deferredPresentationStyleHandles.remove(handle.id)
            terminalCoordinator.removeSurface(for: surfaceKey(handle))
            reportSurfaceStateLater(
                handle,
                state: .disconnected(reason: error.localizedDescription)
            )
            return nil
        }
        if isFirstLaunch, appliesPresentationStyle,
           presentationStyle == nil {
            deferredPresentationStyleHandles.insert(handle.id)
        }
        surface.blocksClipboardReads = attachment.host.isRemote
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

    func surfaceIdentity(handle: BorrowedTmuxSessionHandle) -> UInt? {
        terminalCoordinator.surfaceIdentity(for: surfaceKey(handle))
    }

    private func reportSurfaceStateLater(
        _ handle: BorrowedTmuxSessionHandle,
        state: ConnectionState,
        requiresLiveSurface: Bool = false
    ) {
        Task { [weak self] in
            guard let self, !isShuttingDown else { return }
            let key = sessionKey(handle)
            guard handlesByKey[key] == handle else { return }
            if requiresLiveSurface {
                guard launchedHandles.contains(handle.id),
                      !closedAttachmentHandles.contains(handle.id)
                else { return }
            }
            onStateChanged?(handle, state)
        }
    }

    private func surfaceDidClose(_ handle: BorrowedTmuxSessionHandle) {
        let key = sessionKey(handle)
        guard handlesByKey[key] == handle else { return }
        closedAttachmentHandles.insert(handle.id)
        attachments.removeValue(forKey: handle.id)
        deferredPresentationStyleHandles.remove(handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
        onStateChanged?(
            handle,
            .disconnected(
                reason: "The tmux attachment to “\(handle.name)” closed."
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
        closedAttachmentHandles.removeAll()
        launchedHandles.removeAll()
        deferredPresentationStyleHandles.removeAll()
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

    private func sessionKey(
        _ handle: BorrowedTmuxSessionHandle
    ) -> NativeTmuxSessionKey {
        NativeTmuxSessionKey(
            hostID: handle.hostID,
            name: handle.name,
            socketName: handle.socketName
        )
    }
}
