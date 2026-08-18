import Foundation
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubTmux
import GhosthubTransport
import GhosthubWorkspace

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

enum BorrowedTmuxAttachmentClosure: Equatable {
    case detached
    case processExited(code: UInt32?)
    case launchFailed
    /// The terminal surface could not be created. Transient — no display was
    /// available to render it — so recovery keeps trying instead of latching.
    case surfaceUnavailable
}

private struct NativeTmuxSessionKey: Hashable {
    var hostID: UUID
    var name: String
    var socketName: String?
}

private struct NativeTmuxPathCacheKey: Hashable {
    var host: CommandHost
    var sshConnection: SSHConnectionArgumentsCacheKey
}

private final class NativeTmuxResolutionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var caches: [NativeTmuxPathCacheKey: TmuxPathCache] = [:]

    func resolve(
        key: NativeTmuxPathCacheKey,
        using resolver: @escaping @Sendable ()
            -> Result<ResolvedTmuxBinary, TmuxBinaryError>
    ) -> Result<ResolvedTmuxBinary, TmuxBinaryError> {
        let cache = lock.withLock {
            if let existing = caches[key] {
                return existing
            }
            let created = TmuxPathCache(
                cancellationShell: key.host.displayName,
                resolve: resolver
            )
            caches[key] = created
            return created
        }
        return cache.resolveTmuxBinary()
    }
}

private struct NativeTmuxAttachment {
    var id: UUID
    var host: CommandHost
    var tmuxPath: String
    var kwtPath: String?
    var remoteKwtCommandPrelude: String?
    var windowsKwtRelativePath: String?
    var socketName: String?
    var protectedWorkspacePath: String?
    var launchMode: TmuxAttachmentLaunchMode
    var initialCommand: String?
    var workingDirectory: String?
    var openWorkspace: Bool
    var sshConnectionSnapshot: SSHConnectionArgumentsSnapshot
    var sessionIdentity: TmuxSessionIdentity?
    var paneSplitClientToken: String
    var clientTTYDirectory: String?
    var ignoresClientSize: Bool
    var previewGridSize: TmuxGridSize?
    var supportsPaneSplitting: Bool
    var remoteExitStatusURL: URL?
}

enum TmuxAttachedSessionIdentityResolution: Equatable {
    case pending
    case resolved(TmuxSessionIdentity)
    case unavailable
}

/// Hosts ordinary tmux clients for kwt workspaces and unbound sessions.
/// Tmux owns every window, pane, and byte of history; this coordinator owns
/// only binary resolution and the disposable local libghostty presentation.
@MainActor
final class NativeTmuxSessionCoordinator {
    private struct PaneSplitRequest {
        var shortcut: TerminalPaneSplitShortcut
        var target: TmuxPaneSplitTarget
        var surface: any NativeSessionPaneSurfacing
        var attachmentID: UUID
    }

    private struct PaneSplitWorker {
        var id: UUID
        var task: Task<Void, Never>
    }

    private struct PaneSplitClientBinding {
        var id: UUID
        var task: Task<Void, Never>
    }

    private struct PaneSplitErrorDismissal {
        var id: UUID
        var task: Task<Void, Never>
    }

    private let terminalCoordinator: any NativeSessionSurfaceStoring
    private let tmuxPathProvider:
        @Sendable () -> Result<ResolvedTmuxBinary, TmuxBinaryError>
    private let remoteTmuxPathProvider:
        @Sendable (SSHHostInfo, [String])
        -> Result<ResolvedTmuxBinary, TmuxBinaryError>
    private let sshConnectionArgumentsProvider:
        @Sendable (SSHHostInfo) -> SSHConnectionArgumentsSnapshot
    private let localKwtPathProvider: @Sendable () -> String?
    private let remoteKwtCommandPreludeProvider: @Sendable () -> String?
    private let windowsKwtRelativePathProvider: @Sendable () -> String?
    private let presentationStyleProvider: () -> TmuxPresentationStyle?
    private let appliesPresentationStyleToExistingSessionsProvider:
        () -> Bool
    private let paneSplitter: TmuxPaneSplitter
    private let paneSplitErrorDuration: Duration
    private let clientIdentityRetryDelays: [Duration]
    private let sleep: @Sendable (Duration) async throws -> Void
    private let remoteExitStatusStore: RemoteExitStatusStore
    private var handlesByKey: [NativeTmuxSessionKey: BorrowedTmuxSessionHandle] = [:]
    private var targetHostsByHandle: [UUID: CommandHost] = [:]
    private var attachments: [UUID: NativeTmuxAttachment] = [:]
    private var attachmentClosures: [UUID: BorrowedTmuxAttachmentClosure] = [:]
    private var launchedHandles: Set<UUID> = []
    private var reportedConnectedAttachmentIDs: [UUID: UUID] = [:]
    private let tmuxResolutionCache = NativeTmuxResolutionCache()
    private var provisioningHandles: Set<UUID> = []
    private var provisioningTasks: [UUID: Task<Void, Never>] = [:]
    private var paneSplitRequests: [UUID: [PaneSplitRequest]] = [:]
    private var paneSplitWorkers: [UUID: PaneSplitWorker] = [:]
    private var paneSplitClientBindings: [UUID: PaneSplitClientBinding] = [:]
    private var paneSplitClients: [UUID: TmuxPaneSplitClientIdentity] = [:]
    private var paneSplitErrorDismissals: [UUID: PaneSplitErrorDismissal] = [:]
    private var previewIdentityRetryHandles: Set<UUID> = []
    private var unavailablePreviewIdentityHandles: Set<UUID> = []
    private var deferredPresentationStyleHandles: Set<UUID> = []
    private var interactiveSizingHandles: Set<UUID> = []
    private var isShuttingDown = false

    var onStateChanged: ((BorrowedTmuxSessionHandle, ConnectionState) -> Void)?
    var onSurfaceReady: ((BorrowedTmuxSessionHandle) -> Void)?
    var onAttachedSessionIdentityUnavailable:
        ((BorrowedTmuxSessionHandle) -> Void)?

    init(
        terminalCoordinator: any NativeSessionSurfaceStoring,
        tmuxPathProvider: @escaping @Sendable ()
            -> Result<ResolvedTmuxBinary, TmuxBinaryError>,
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
        remoteTmuxPathProvider: @escaping @Sendable (SSHHostInfo, [String])
            -> Result<ResolvedTmuxBinary, TmuxBinaryError> = {
                TmuxBinaryResolver().resolveTmuxBinary(
                    on: $0,
                    sshConnectionArguments: $1
                )
            },
        sshConnectionArgumentsProvider:
        @escaping @Sendable (SSHHostInfo)
            -> SSHConnectionArgumentsSnapshot = {
                let snapshot = SSHConnectionPool.configurationSnapshot(for: $0)
                let provider = snapshot.configurationProvider
                let controlPath = SSHConnectionPool.authenticationIdentity(
                    for: snapshot
                )?.controlPath
                let connectionSnapshot = SSHConfigurationResolver
                    .connectionArgumentsSnapshot(
                        for: $0,
                        configurationProvider: provider
                    )
                return connectionSnapshot.replacingArguments(
                    demoSSHIsolationArguments()
                        + connectionSnapshot.arguments
                        + SSHConnectionPool.proxyArguments(
                            for: snapshot.target,
                            configurationProvider: provider
                        )
                        + SSHConnectionPool.connectionArguments(
                            controlPath: controlPath
                        )
                        + SSHConfigurationResolver.noninteractiveHostKeyArguments(
                            for: $0,
                            configurationProvider: provider
                        )
                )
            },
        paneSplitter: TmuxPaneSplitter = TmuxPaneSplitter(),
        paneSplitErrorDuration: Duration = .seconds(4),
        clientIdentityRetryDelays: [Duration] = [
            .milliseconds(250), .seconds(1),
        ],
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        remoteExitStatusDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-tmux-exit-\(UUID().uuidString)",
                isDirectory: true
            )
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
        self.sshConnectionArgumentsProvider =
            sshConnectionArgumentsProvider
        self.paneSplitter = paneSplitter
        self.paneSplitErrorDuration = paneSplitErrorDuration
        self.clientIdentityRetryDelays = clientIdentityRetryDelays
        self.sleep = sleep
        remoteExitStatusStore = RemoteExitStatusStore(
            directory: remoteExitStatusDirectory
        )
    }

    func attach(
        hostID: UUID,
        name: String,
        host: CommandHost,
        socketName: String? = nil,
        launchMode: TmuxAttachmentLaunchMode = .attach,
        initialCommand: String? = nil,
        workingDirectory: String? = nil,
        openWorkspace: Bool = false,
        sessionIdentity: TmuxSessionIdentity? = nil,
        ignoresClientSize: Bool = false,
        previewGridSize: TmuxGridSize? = nil
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
        attachmentClosures.removeValue(forKey: handle.id)

        guard !isShuttingDown,
              attachments[handle.id] == nil,
              !provisioningHandles.contains(handle.id)
        else { return handle }

        provisioningHandles.insert(handle.id)
        onStateChanged?(handle, .connecting)
        let tmuxResolutionCache = tmuxResolutionCache
        let tmuxPathProvider = tmuxPathProvider
        let remoteTmuxPathProvider = remoteTmuxPathProvider
        let sshConnectionArgumentsProvider =
            sshConnectionArgumentsProvider
        provisioningTasks[handle.id] = Task { [weak self] in
            let probe = Task.detached(priority: .userInitiated) {
                let sshConnectionSnapshot: SSHConnectionArgumentsSnapshot
                if case let .ssh(info) = host {
                    sshConnectionSnapshot =
                        sshConnectionArgumentsProvider(info)
                } else {
                    sshConnectionSnapshot = SSHConnectionArgumentsSnapshot(
                        arguments: []
                    )
                }
                let cacheKey = NativeTmuxPathCacheKey(
                    host: host,
                    sshConnection: sshConnectionSnapshot.cacheKey
                )
                let resolution = tmuxResolutionCache.resolve(key: cacheKey) {
                    switch host {
                    case .local:
                        return tmuxPathProvider()
                    case let .ssh(info):
                        return remoteTmuxPathProvider(
                            info,
                            sshConnectionSnapshot.arguments
                        )
                    }
                }
                return (resolution, sshConnectionSnapshot, cacheKey)
            }
            let (resolution, sshConnectionSnapshot, cacheKey) =
                await withTaskCancellationHandler {
                    await probe.value
                } onCancel: {
                    probe.cancel()
                }
            self?.finishAttach(
                handle: handle,
                host: host,
                socketName: socketName,
                launchMode: launchMode,
                initialCommand: launchMode == .create ? initialCommand : nil,
                workingDirectory: workingDirectory,
                openWorkspace: openWorkspace,
                sessionIdentity: sessionIdentity,
                ignoresClientSize: ignoresClientSize,
                previewGridSize: previewGridSize,
                sshConnectionSnapshot: sshConnectionSnapshot,
                tmuxPathCacheKey: cacheKey,
                resolution: resolution
            )
        }
        return handle
    }

    private func finishAttach(
        handle: BorrowedTmuxSessionHandle,
        host: CommandHost,
        socketName: String?,
        launchMode: TmuxAttachmentLaunchMode,
        initialCommand: String?,
        workingDirectory: String?,
        openWorkspace: Bool,
        sessionIdentity: TmuxSessionIdentity?,
        ignoresClientSize: Bool,
        previewGridSize: TmuxGridSize?,
        sshConnectionSnapshot: SSHConnectionArgumentsSnapshot,
        tmuxPathCacheKey: NativeTmuxPathCacheKey,
        resolution: Result<ResolvedTmuxBinary, TmuxBinaryError>
    ) {
        provisioningTasks.removeValue(forKey: handle.id)
        provisioningHandles.remove(handle.id)
        let key = sessionKey(handle)
        guard handlesByKey[key] == handle,
              targetHostsByHandle[handle.id] == host,
              attachments[handle.id] == nil else { return }
        switch resolution {
        case let .success(resolved):
            let attachmentID = UUID()
            let enablesInteractiveSizing = interactiveSizingHandles.remove(
                handle.id
            ) != nil
            let protectedWorkspacePath = socketName == nil
                ? nil
                : workingDirectory
            attachments[handle.id] = NativeTmuxAttachment(
                id: attachmentID,
                host: host,
                tmuxPath: resolved.path,
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
                initialCommand: launchMode == .create ? initialCommand : nil,
                workingDirectory: workingDirectory,
                openWorkspace: openWorkspace,
                sshConnectionSnapshot: sshConnectionSnapshot,
                sessionIdentity: sessionIdentity,
                paneSplitClientToken: attachmentID.uuidString.lowercased(),
                clientTTYDirectory: host.isRemote ? nil : StateHome.resolved()
                    .appendingPathComponent(
                        "tmux-clients", isDirectory: true
                    ).path,
                ignoresClientSize: enablesInteractiveSizing
                    ? false : ignoresClientSize,
                previewGridSize: enablesInteractiveSizing
                    ? nil : previewGridSize,
                supportsPaneSplitting: TmuxPaneSplitter
                    .supportsPaneSplitting(
                        version: resolved.version,
                        host: host
                    ),
                remoteExitStatusURL: host.isRemote
                    ? remoteExitStatusStore.prepare()
                    : nil
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
        cancelPaneSplits(handleID: handle.id)
        provisioningHandles.remove(handle.id)
        targetHostsByHandle.removeValue(forKey: handle.id)
        remoteExitStatusStore.remove(
            attachments.removeValue(forKey: handle.id)?.remoteExitStatusURL
        )
        attachmentClosures.removeValue(forKey: handle.id)
        launchedHandles.remove(handle.id)
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
        deferredPresentationStyleHandles.remove(handle.id)
        interactiveSizingHandles.remove(handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
    }

    func hasLaunched(_ handle: BorrowedTmuxSessionHandle) -> Bool {
        launchedHandles.contains(handle.id)
    }

    func hasClosedAttachment(_ handle: BorrowedTmuxSessionHandle) -> Bool {
        attachmentClosures[handle.id] != nil
    }

    func attachmentClosure(
        _ handle: BorrowedTmuxSessionHandle
    ) -> BorrowedTmuxAttachmentClosure? {
        attachmentClosures[handle.id]
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

    func updatePreviewGridSize(
        _ gridSize: TmuxGridSize?,
        for handle: BorrowedTmuxSessionHandle
    ) {
        // Inventory refreshes repeat the current grid. Reapplying it resizes
        // and rerenders every hidden surface even when tmux did not change.
        guard var attachment = attachments[handle.id],
              attachment.ignoresClientSize,
              attachment.previewGridSize != gridSize
        else { return }
        attachment.previewGridSize = gridSize
        attachments[handle.id] = attachment
        guard let gridSize,
              let surface = terminalCoordinator.paneSurfaceIfPresent(
                  for: surfaceKey(handle)
              )
        else { return }
        _ = surface.sizeForPreviewGrid(
            columns: gridSize.columns,
            rows: gridSize.rows
        )
    }

    func enableInteractiveSizing(
        for handle: BorrowedTmuxSessionHandle
    ) async -> TmuxPaneSplitFailure? {
        guard var attachment = attachments[handle.id] else {
            if provisioningHandles.contains(handle.id) {
                interactiveSizingHandles.insert(handle.id)
                return nil
            }
            return TmuxPaneSplitFailure(
                host: targetHostsByHandle[handle.id]?.displayName
                    ?? "the selected host",
                sessionName: handle.name,
                status: 75,
                diagnostic: "The tmux attachment is unavailable."
            )
        }
        guard attachment.ignoresClientSize else { return nil }
        guard launchedHandles.contains(handle.id) else {
            attachment.ignoresClientSize = false
            attachment.previewGridSize = nil
            attachments[handle.id] = attachment
            return nil
        }
        let attachmentID = attachment.id
        var target = paneSplitTarget(
            handle: handle,
            attachment: attachment,
            expectedIdentity: attachment.sessionIdentity
        )
        switch await paneSplitter.clientIdentity(target: target) {
        case let .success(client):
            guard !Task.isCancelled,
                  attachments[handle.id]?.id == attachmentID
            else { return nil }
            if let expectedClient = target.expectedClient,
               !client.matchesClient(expectedClient) {
                return TmuxPaneSplitFailure(
                    host: target.host.displayName,
                    sessionName: target.sessionName,
                    status: 75,
                    diagnostic: "The attached tmux session changed."
                )
            }
            paneSplitClients[handle.id] = client
            target.expectedIdentity = client.sessionIdentity
            target.expectedClient = client
        case let .failure(failure):
            return failure
        }
        let failure = await paneSplitter.enableSizing(target: target)
        guard !Task.isCancelled,
              attachments[handle.id]?.id == attachmentID
        else { return nil }
        guard failure == nil else { return failure }
        var promoted = attachment
        promoted.ignoresClientSize = false
        promoted.previewGridSize = nil
        attachments[handle.id] = promoted
        terminalCoordinator.paneSurfaceIfPresent(
            for: surfaceKey(handle)
        )?.clearPreviewGridSize()
        return nil
    }

    func surface(handle: BorrowedTmuxSessionHandle) -> TerminalSurfaceView? {
        guard attachmentClosures[handle.id] == nil,
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
            launchMode: attachment.launchMode,
            initialCommand: attachment.initialCommand,
            ignoresClientSize: attachment.ignoresClientSize,
            initialClientSize: attachment.previewGridSize.map {
                TmuxClientSize(columns: $0.columns, rows: $0.rows)
            }
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
                    workingDirectory: attachment.workingDirectory,
                    sshConnectionArguments:
                    attachment.sshConnectionSnapshot.arguments,
                    remoteExitStatusPath:
                    attachment.remoteExitStatusURL?.path,
                    clientTTYToken: attachment.paneSplitClientToken,
                    localClientTTYDirectory: attachment.clientTTYDirectory
                )
            )
        )
        guard let surface else {
            failSurfaceLaunch(
                handle,
                reason: "Ghosthub could not create the terminal surface."
            )
            return nil
        }
        if let error = surface.launchError {
            failSurfaceLaunch(
                handle,
                reason: error.localizedDescription,
                closure: surface.launchFailureIsRetryable
                    ? .surfaceUnavailable : .launchFailed
            )
            return nil
        }
        if isFirstLaunch, appliesPresentationStyle,
           presentationStyle == nil {
            deferredPresentationStyleHandles.insert(handle.id)
        }
        surface.blocksClipboardReads = attachment.host.isRemote
        if attachment.ignoresClientSize,
           let previewGridSize = attachment.previewGridSize {
            _ = surface.sizeForPreviewGrid(
                columns: previewGridSize.columns,
                rows: previewGridSize.rows
            )
        }
        let splitTarget = TmuxPaneSplitTarget(
            host: attachment.host,
            tmuxPath: attachment.tmuxPath,
            sessionName: handle.name,
            socketName: attachment.socketName,
            sshConnectionArguments: attachment.sshConnectionSnapshot.arguments,
            expectedIdentity: attachment.sessionIdentity,
            clientToken: attachment.paneSplitClientToken,
            clientTTYDirectory: attachment.clientTTYDirectory,
            expectedClient: paneSplitClients[handle.id]
        )
        if attachment.supportsPaneSplitting {
            surface.paneSplitShortcutHandler = {
                [weak self, weak surface] shortcut in
                guard let self, let surface else { return }
                enqueuePaneSplit(
                    shortcut,
                    target: splitTarget,
                    surface: surface,
                    handle: handle,
                    attachmentID: attachment.id
                )
            }
        }
        surface.registerSurfaceCloseObserver(
            id: handle.id,
            onSurfaceClosed: { [weak self] processAlive, childExitCode in
                self?.surfaceDidClose(
                    handle,
                    processAlive: processAlive,
                    childExitCode: childExitCode
                )
            }
        )
        launchedHandles.insert(handle.id)
        startPaneSplitClientBinding(
            target: splitTarget,
            handle: handle,
            attachmentID: attachment.id
        )
        if reportedConnectedAttachmentIDs[handle.id] != attachment.id {
            reportedConnectedAttachmentIDs[handle.id] = attachment.id
            reportSurfaceStateLater(
                handle,
                state: .connected,
                requiredAttachmentID: attachment.id
            )
        }
        return surface as? TerminalSurfaceView
    }

    private func enqueuePaneSplit(
        _ shortcut: TerminalPaneSplitShortcut,
        target: TmuxPaneSplitTarget,
        surface: any NativeSessionPaneSurfacing,
        handle: BorrowedTmuxSessionHandle,
        attachmentID: UUID
    ) {
        guard let client = paneSplitClients[handle.id] else {
            presentPaneSplitError(TmuxPaneSplitFailure(
                host: target.host.displayName,
                sessionName: target.sessionName,
                status: 75,
                diagnostic: "The attached tmux client identity is unavailable."
            ), on: surface, handle: handle, attachmentID: attachmentID)
            startPaneSplitClientBinding(
                target: target,
                handle: handle,
                attachmentID: attachmentID
            )
            return
        }
        var target = target
        target.expectedClient = client
        paneSplitRequests[handle.id, default: []].append(PaneSplitRequest(
            shortcut: shortcut,
            target: target,
            surface: surface,
            attachmentID: attachmentID
        ))
        guard paneSplitWorkers[handle.id] == nil else { return }

        let workerID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await runPaneSplitQueue(
                handle: handle,
                workerID: workerID
            )
        }
        paneSplitWorkers[handle.id] = PaneSplitWorker(
            id: workerID,
            task: task
        )
    }

    private func paneSplitTarget(
        handle: BorrowedTmuxSessionHandle,
        attachment: NativeTmuxAttachment,
        expectedIdentity: TmuxSessionIdentity?
    ) -> TmuxPaneSplitTarget {
        TmuxPaneSplitTarget(
            host: attachment.host,
            tmuxPath: attachment.tmuxPath,
            sessionName: handle.name,
            socketName: attachment.socketName,
            sshConnectionArguments: attachment.sshConnectionSnapshot.arguments,
            expectedIdentity: expectedIdentity,
            clientToken: attachment.paneSplitClientToken,
            clientTTYDirectory: attachment.clientTTYDirectory,
            expectedClient: paneSplitClients[handle.id]
        )
    }

    private func runPaneSplitQueue(
        handle: BorrowedTmuxSessionHandle,
        workerID: UUID
    ) async {
        defer {
            if paneSplitWorkers[handle.id]?.id == workerID {
                paneSplitWorkers.removeValue(forKey: handle.id)
                paneSplitRequests.removeValue(forKey: handle.id)
            }
        }

        while !Task.isCancelled {
            guard paneSplitWorkers[handle.id]?.id == workerID,
                  var requests = paneSplitRequests[handle.id],
                  !requests.isEmpty
            else { return }
            let request = requests.removeFirst()
            paneSplitRequests[handle.id] = requests
            guard attachments[handle.id]?.id == request.attachmentID,
                  launchedHandles.contains(handle.id)
            else { continue }

            clearPaneSplitError(
                on: request.surface,
                handleID: handle.id
            )
            var target = request.target
            let expectedClient = target.expectedClient
                ?? paneSplitClients[handle.id]
            target.expectedClient = expectedClient
            switch await paneSplitter.clientIdentity(target: target) {
            case let .success(client):
                guard attachments[handle.id]?.id == request.attachmentID
                else { return }
                if let expectedClient,
                   !client.matchesClient(expectedClient) {
                    let failure = TmuxPaneSplitFailure(
                        host: target.host.displayName,
                        sessionName: target.sessionName,
                        status: 75,
                        diagnostic: "The attached tmux session changed."
                    )
                    presentPaneSplitError(
                        failure,
                        on: request.surface,
                        handle: handle,
                        attachmentID: request.attachmentID
                    )
                    continue
                }
                paneSplitClients[handle.id] = client
                target.expectedIdentity = client.sessionIdentity
                target.expectedClient = client
            case let .failure(failure):
                guard !Task.isCancelled,
                      paneSplitWorkers[handle.id]?.id == workerID,
                      attachments[handle.id]?.id == request.attachmentID
                else { return }
                presentPaneSplitError(
                    failure,
                    on: request.surface,
                    handle: handle,
                    attachmentID: request.attachmentID
                )
                continue
            }
            var failure = await paneSplitter.split(
                request.shortcut,
                target: target
            )
            guard !Task.isCancelled,
                  paneSplitWorkers[handle.id]?.id == workerID,
                  attachments[handle.id]?.id == request.attachmentID
            else { return }
            if failure?.kind == .atomicGuardChanged,
               let expectedClient = target.expectedClient {
                switch await paneSplitter.clientIdentity(target: target) {
                case let .success(client):
                    guard !Task.isCancelled,
                          paneSplitWorkers[handle.id]?.id == workerID,
                          attachments[handle.id]?.id == request.attachmentID
                    else { return }
                    guard client.matchesClient(expectedClient) else {
                        failure = TmuxPaneSplitFailure(
                            host: target.host.displayName,
                            sessionName: target.sessionName,
                            status: 75,
                            diagnostic: "The attached tmux session changed."
                        )
                        break
                    }
                    paneSplitClients[handle.id] = client
                    target.expectedClient = client
                    failure = await paneSplitter.split(
                        request.shortcut,
                        target: target
                    )
                    guard !Task.isCancelled,
                          paneSplitWorkers[handle.id]?.id == workerID,
                          attachments[handle.id]?.id == request.attachmentID
                    else { return }
                case let .failure(identityFailure):
                    failure = identityFailure
                }
            }
            if let failure {
                presentPaneSplitError(
                    failure,
                    on: request.surface,
                    handle: handle,
                    attachmentID: request.attachmentID
                )
                AppLogger.shared.error(
                    "tmux pane split: \(failure.localizedDescription)"
                )
            } else {
                clearPaneSplitError(
                    on: request.surface,
                    handleID: handle.id
                )
            }
        }
    }

    private func startPaneSplitClientBinding(
        target: TmuxPaneSplitTarget,
        handle: BorrowedTmuxSessionHandle,
        attachmentID: UUID
    ) {
        guard attachments[handle.id]?.id == attachmentID,
              launchedHandles.contains(handle.id),
              paneSplitClients[handle.id] == nil,
              paneSplitClientBindings[handle.id] == nil
        else { return }
        guard attachments[handle.id]?.supportsPaneSplitting == true else {
            if previewIdentityRetryHandles.remove(handle.id) != nil {
                unavailablePreviewIdentityHandles.insert(handle.id)
                onAttachedSessionIdentityUnavailable?(handle)
            }
            return
        }

        let bindingID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if paneSplitClientBindings[handle.id]?.id == bindingID {
                    paneSplitClientBindings.removeValue(forKey: handle.id)
                }
            }
            var retryIndex = 0
            while !Task.isCancelled {
                let result = await paneSplitter.clientIdentity(target: target)
                guard !Task.isCancelled,
                      paneSplitClientBindings[handle.id]?.id == bindingID,
                      attachments[handle.id]?.id == attachmentID
                else { return }
                if case let .success(client) = result {
                    paneSplitClientBindings.removeValue(forKey: handle.id)
                    paneSplitClients[handle.id] = client
                    previewIdentityRetryHandles.remove(handle.id)
                    unavailablePreviewIdentityHandles.remove(handle.id)
                    if let surface = terminalCoordinator.paneSurfaceIfPresent(
                        for: surfaceKey(handle)
                    ) {
                        clearPaneSplitError(on: surface, handleID: handle.id)
                    }
                    onSurfaceReady?(handle)
                    return
                }
                guard previewIdentityRetryHandles.contains(handle.id),
                      retryIndex < clientIdentityRetryDelays.count
                else {
                    paneSplitClientBindings.removeValue(forKey: handle.id)
                    if previewIdentityRetryHandles.remove(handle.id) != nil {
                        unavailablePreviewIdentityHandles.insert(handle.id)
                        onAttachedSessionIdentityUnavailable?(handle)
                    }
                    return
                }
                let delay = clientIdentityRetryDelays[retryIndex]
                retryIndex += 1
                do {
                    try await sleep(delay)
                } catch {
                    return
                }
            }
        }
        paneSplitClientBindings[handle.id] = PaneSplitClientBinding(
            id: bindingID,
            task: task
        )
    }

    private func cancelPaneSplits(handleID: UUID) {
        paneSplitClientBindings.removeValue(forKey: handleID)?.task.cancel()
        paneSplitWorkers.removeValue(forKey: handleID)?.task.cancel()
        paneSplitErrorDismissals.removeValue(forKey: handleID)?.task.cancel()
        paneSplitRequests.removeValue(forKey: handleID)
        paneSplitClients.removeValue(forKey: handleID)
        previewIdentityRetryHandles.remove(handleID)
        unavailablePreviewIdentityHandles.remove(handleID)
    }

    private func presentPaneSplitError(
        _ failure: TmuxPaneSplitFailure,
        on surface: any NativeSessionPaneSurfacing,
        handle: BorrowedTmuxSessionHandle,
        attachmentID: UUID
    ) {
        paneSplitErrorDismissals.removeValue(forKey: handle.id)?.task.cancel()
        surface.paneSplitErrorMessage = failure.localizedDescription
        let dismissalID = UUID()
        let duration = paneSplitErrorDuration
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self,
                  paneSplitErrorDismissals[handle.id]?.id == dismissalID,
                  attachments[handle.id]?.id == attachmentID
            else { return }
            paneSplitErrorDismissals.removeValue(forKey: handle.id)
            surface.paneSplitErrorMessage = nil
        }
        paneSplitErrorDismissals[handle.id] = PaneSplitErrorDismissal(
            id: dismissalID,
            task: task
        )
    }

    private func clearPaneSplitError(
        on surface: any NativeSessionPaneSurfacing,
        handleID: UUID
    ) {
        paneSplitErrorDismissals.removeValue(forKey: handleID)?.task.cancel()
        surface.paneSplitErrorMessage = nil
    }

    private func failSurfaceLaunch(
        _ handle: BorrowedTmuxSessionHandle,
        reason: String,
        closure: BorrowedTmuxAttachmentClosure = .launchFailed
    ) {
        AppLogger.shared.error(
            "tmux surface launch failed: \(reason) "
                + "retryable=\(closure == .surfaceUnavailable) "
                + "activeDisplays=\(DisplayAvailability.activeCount())",
            context: "tmux"
        )
        cancelPaneSplits(handleID: handle.id)
        attachmentClosures[handle.id] = closure
        remoteExitStatusStore.remove(
            attachments.removeValue(forKey: handle.id)?.remoteExitStatusURL
        )
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
        deferredPresentationStyleHandles.remove(handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
        reportSurfaceStateLater(
            handle,
            state: .disconnected(reason: reason)
        )
    }

    func surfaceIdentity(handle: BorrowedTmuxSessionHandle) -> UInt? {
        terminalCoordinator.surfaceIdentity(for: surfaceKey(handle))
    }

    func supportsPaneSplitting(_ handle: BorrowedTmuxSessionHandle) -> Bool {
        attachments[handle.id]?.supportsPaneSplitting == true
    }

    func attachedSessionIdentity(
        _ handle: BorrowedTmuxSessionHandle
    ) -> TmuxSessionIdentity? {
        guard attachments[handle.id] != nil,
              launchedHandles.contains(handle.id)
        else { return nil }
        return paneSplitClients[handle.id]?.sessionIdentity
    }

    func attachedSessionIdentityResolution(
        _ handle: BorrowedTmuxSessionHandle
    ) -> TmuxAttachedSessionIdentityResolution {
        guard attachments[handle.id] != nil,
              launchedHandles.contains(handle.id)
        else { return .pending }
        if let identity = paneSplitClients[handle.id]?.sessionIdentity {
            return .resolved(identity)
        }
        return unavailablePreviewIdentityHandles.contains(handle.id)
            ? .unavailable
            : .pending
    }

    func requestAttachedSessionIdentity(
        _ handle: BorrowedTmuxSessionHandle
    ) {
        guard let attachment = attachments[handle.id],
              launchedHandles.contains(handle.id)
        else { return }
        previewIdentityRetryHandles.insert(handle.id)
        startPaneSplitClientBinding(
            target: paneSplitTarget(
                handle: handle,
                attachment: attachment,
                expectedIdentity: attachment.sessionIdentity
            ),
            handle: handle,
            attachmentID: attachment.id
        )
    }

    func revalidateAttachedSessionIdentity(
        _ handle: BorrowedTmuxSessionHandle
    ) async -> TmuxSessionIdentity? {
        guard let attachment = attachments[handle.id],
              attachment.supportsPaneSplitting,
              launchedHandles.contains(handle.id),
              paneSplitClients[handle.id] != nil
        else { return nil }
        let attachmentID = attachment.id
        let result = await paneSplitter.clientIdentity(
            target: paneSplitTarget(
                handle: handle,
                attachment: attachment,
                expectedIdentity: nil
            ),
            priority: .utility
        )
        guard !Task.isCancelled,
              attachments[handle.id]?.id == attachmentID,
              launchedHandles.contains(handle.id),
              case let .success(client) = result
        else { return nil }
        return client.sessionIdentity
    }

    func requestPaneSplit(
        _ shortcut: TerminalPaneSplitShortcut,
        handle: BorrowedTmuxSessionHandle,
        requiresKeyboardFocus: Bool
    ) {
        guard let surface = terminalCoordinator.paneSurfaceIfPresent(
            for: surfaceKey(handle)
        ),
            !requiresKeyboardFocus || surface.hasEffectiveKeyboardFocus
        else { return }
        surface.paneSplitShortcutHandler?(shortcut)
    }

    private func reportSurfaceStateLater(
        _ handle: BorrowedTmuxSessionHandle,
        state: ConnectionState,
        requiredAttachmentID: UUID? = nil
    ) {
        Task { [weak self] in
            guard let self, !isShuttingDown else { return }
            let key = sessionKey(handle)
            guard handlesByKey[key] == handle else { return }
            if let requiredAttachmentID {
                guard attachments[handle.id]?.id == requiredAttachmentID,
                      launchedHandles.contains(handle.id),
                      attachmentClosures[handle.id] == nil
                else { return }
            }
            onStateChanged?(handle, state)
        }
    }

    private func surfaceDidClose(
        _ handle: BorrowedTmuxSessionHandle,
        processAlive: Bool,
        childExitCode: UInt32?
    ) {
        let key = sessionKey(handle)
        guard handlesByKey[key] == handle else { return }
        let attachment = attachments.removeValue(forKey: handle.id)
        cancelPaneSplits(handleID: handle.id)
        let recordedExitCode = remoteExitStatusStore.consume(
            attachment?.remoteExitStatusURL
        )
        if let recordedExitCode {
            attachmentClosures[handle.id] = recordedExitCode == 0
                ? .detached
                : .processExited(code: recordedExitCode)
        } else {
            attachmentClosures[handle.id] = processAlive || childExitCode == 0
                ? .detached
                : .processExited(code: childExitCode)
        }
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
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
        paneSplitClientBindings.values.forEach { $0.task.cancel() }
        paneSplitWorkers.values.forEach { $0.task.cancel() }
        paneSplitErrorDismissals.values.forEach { $0.task.cancel() }
        provisioningTasks.removeAll()
        paneSplitClientBindings.removeAll()
        paneSplitWorkers.removeAll()
        paneSplitErrorDismissals.removeAll()
        paneSplitRequests.removeAll()
        paneSplitClients.removeAll()
        previewIdentityRetryHandles.removeAll()
        unavailablePreviewIdentityHandles.removeAll()
        provisioningHandles.removeAll()
        handlesByKey.removeAll()
        targetHostsByHandle.removeAll()
        for value in attachments.values {
            remoteExitStatusStore.remove(value.remoteExitStatusURL)
        }
        attachments.removeAll()
        attachmentClosures.removeAll()
        launchedHandles.removeAll()
        reportedConnectedAttachmentIDs.removeAll()
        deferredPresentationStyleHandles.removeAll()
        interactiveSizingHandles.removeAll()
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
