import Foundation
import GhosthubTerminal
import GhosthubTmux
import GhosthubWorkspace

@MainActor
protocol TmuxPaneSurfacing: AnyObject {
    var blocksClipboardReads: Bool { get set }
    var launchError: Error? { get }
    var childExitCode: UInt32? { get }
    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool, UInt32?) -> Void
    )
}

extension TerminalSurfaceView: TmuxPaneSurfacing {
    var launchError: Error? { error }

    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool, UInt32?) -> Void
    ) {
        registerSurfaceCloseObserver(id: id) { [weak self] processAlive in
            onSurfaceClosed(processAlive, self?.childExitCode)
        }
    }
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

enum BorrowedTmuxAttachmentClosure: Equatable {
    case detached
    case processExited(code: UInt32?)
    case launchFailed
}

private struct NativeTmuxSessionKey: Hashable {
    var hostID: UUID
    var name: String
    var socketName: String?
}

private struct NativeTmuxAttachment {
    var id: UUID
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
    var sshConnectionArguments: [String]
    var remoteExitStatusURL: URL?
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
    private let sshConnectionArgumentsProvider:
        @Sendable (SSHHostInfo) -> [String]
    private let localKwtPathProvider: @Sendable () -> String?
    private let remoteKwtCommandPreludeProvider: @Sendable () -> String?
    private let windowsKwtRelativePathProvider: @Sendable () -> String?
    private let presentationStyleProvider: () -> TmuxPresentationStyle?
    private let appliesPresentationStyleToExistingSessionsProvider:
        () -> Bool
    private let remoteExitStatusDirectory: URL
    private var handlesByKey: [NativeTmuxSessionKey: BorrowedTmuxSessionHandle] = [:]
    private var targetHostsByHandle: [UUID: TmuxHost] = [:]
    private var attachments: [UUID: NativeTmuxAttachment] = [:]
    private var attachmentClosures: [UUID: BorrowedTmuxAttachmentClosure] = [:]
    private var launchedHandles: Set<UUID> = []
    private var reportedConnectedAttachmentIDs: [UUID: UUID] = [:]
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
            },
        sshConnectionArgumentsProvider:
        @escaping @Sendable (SSHHostInfo) -> [String] = {
            SSHConnectionPool.connectionArguments(for: $0)
                + SSHConfigurationResolver.noninteractiveHostKeyArguments(
                    for: $0
                )
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
        self.remoteExitStatusDirectory = remoteExitStatusDirectory
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
        attachmentClosures.removeValue(forKey: handle.id)

        guard !isShuttingDown,
              attachments[handle.id] == nil,
              !provisioningHandles.contains(handle.id)
        else { return handle }

        provisioningHandles.insert(handle.id)
        onStateChanged?(handle, .connecting)
        let cachedPath = tmuxPathsByHost[host]
        let tmuxPathProvider = tmuxPathProvider
        let remoteTmuxPathProvider = remoteTmuxPathProvider
        let sshConnectionArgumentsProvider =
            sshConnectionArgumentsProvider
        provisioningTasks[handle.id] = Task { [weak self] in
            let probe = Task.detached(priority: .userInitiated) {
                let resolution: Result<String, TmuxBinaryError>
                if let cachedPath {
                    resolution = .success(cachedPath)
                } else {
                    switch host {
                    case .local:
                        resolution = tmuxPathProvider()
                    case let .ssh(info):
                        resolution = remoteTmuxPathProvider(info)
                    }
                }
                let sshConnectionArguments: [String]
                if case let .ssh(info) = host {
                    sshConnectionArguments =
                        sshConnectionArgumentsProvider(info)
                } else {
                    sshConnectionArguments = []
                }
                return (resolution, sshConnectionArguments)
            }
            let (resolution, sshConnectionArguments) =
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
                workingDirectory: workingDirectory,
                openWorkspace: openWorkspace,
                sshConnectionArguments: sshConnectionArguments,
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
        sshConnectionArguments: [String],
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
                id: UUID(),
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
                openWorkspace: openWorkspace,
                sshConnectionArguments: sshConnectionArguments,
                remoteExitStatusURL: host.isRemote
                    ? prepareRemoteExitStatusFile()
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
        provisioningHandles.remove(handle.id)
        targetHostsByHandle.removeValue(forKey: handle.id)
        removeRemoteExitStatusFile(attachments.removeValue(forKey: handle.id))
        attachmentClosures.removeValue(forKey: handle.id)
        launchedHandles.remove(handle.id)
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
        deferredPresentationStyleHandles.remove(handle.id)
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
                    workingDirectory: attachment.workingDirectory,
                    sshConnectionArguments: tmuxSSHConnectionArguments()
                        + attachment.sshConnectionArguments,
                    remoteExitStatusPath:
                    attachment.remoteExitStatusURL?.path
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
            failSurfaceLaunch(handle, reason: error.localizedDescription)
            return nil
        }
        if isFirstLaunch, appliesPresentationStyle,
           presentationStyle == nil {
            deferredPresentationStyleHandles.insert(handle.id)
        }
        surface.blocksClipboardReads = attachment.host.isRemote
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

    private func failSurfaceLaunch(
        _ handle: BorrowedTmuxSessionHandle,
        reason: String
    ) {
        attachmentClosures[handle.id] = .launchFailed
        removeRemoteExitStatusFile(attachments.removeValue(forKey: handle.id))
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
        let recordedExitCode = consumeRemoteExitStatus(attachment)
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
        provisioningTasks.removeAll()
        provisioningHandles.removeAll()
        handlesByKey.removeAll()
        targetHostsByHandle.removeAll()
        attachments.values.forEach(removeRemoteExitStatusFile)
        attachments.removeAll()
        attachmentClosures.removeAll()
        launchedHandles.removeAll()
        reportedConnectedAttachmentIDs.removeAll()
        deferredPresentationStyleHandles.removeAll()
        for handle in handles {
            terminalCoordinator.removeSurface(for: surfaceKey(handle))
        }
    }

    private func prepareRemoteExitStatusFile() -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: remoteExitStatusDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = remoteExitStatusDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: false
            )
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else { return nil }
            return url
        } catch {
            return nil
        }
    }

    private func consumeRemoteExitStatus(
        _ attachment: NativeTmuxAttachment?
    ) -> UInt32? {
        guard let url = attachment?.remoteExitStatusURL else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return UInt32(value)
    }

    private func removeRemoteExitStatusFile(
        _ attachment: NativeTmuxAttachment?
    ) {
        guard let url = attachment?.remoteExitStatusURL else { return }
        try? FileManager.default.removeItem(at: url)
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
