import Foundation
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubTransport
import GhosthubWorkspace
import GhosthubZellij

struct BorrowedZellijSessionHandle: Equatable, Sendable {
    var id: UUID
    var hostID: UUID
    var name: String
    var surfaceID: UUID
}

enum BorrowedZellijAttachmentClosure: Equatable {
    case detached
    case processExited(code: UInt32?)
    case launchFailed
    /// The terminal surface could not be created. Transient — no display was
    /// available to render it — so recovery keeps trying instead of latching.
    case surfaceUnavailable
}

private struct NativeZellijSessionKey: Hashable {
    var hostID: UUID
    var name: String
}

private struct NativeZellijAttachment {
    var id: UUID
    var host: CommandHost
    var zellijPath: String
    var launchMode: ZellijAttachmentLaunchMode
    var sshConnectionSnapshot: SSHConnectionArgumentsSnapshot
    var sshConnection: KwtSSHConnection?
    var remoteExitStatusURL: URL?
}

/// Hosts disposable Zellij clients. Zellij owns the server, processes, tabs,
/// panes, layout, history, and keybindings; this coordinator owns presentation.
@MainActor
final class NativeZellijSessionCoordinator {
    private let terminalCoordinator: any NativeSessionSurfaceStoring
    private let zellijPathProvider:
        @Sendable (CommandHost, [String]) -> Result<String, ZellijCommandError>
    private let remoteConnectionProvider:
        @Sendable (UUID, SSHHostInfo) async throws
        -> KwtSSHConnection
    private let remoteExitStatusStore: RemoteExitStatusStore
    private var handlesByKey: [
        NativeZellijSessionKey: BorrowedZellijSessionHandle
    ] = [:]
    private var targetHostsByHandle: [UUID: CommandHost] = [:]
    private var attachments: [UUID: NativeZellijAttachment] = [:]
    private var attachmentClosures: [
        UUID: BorrowedZellijAttachmentClosure
    ] = [:]
    private var launchedHandles: Set<UUID> = []
    private var reportedConnectedAttachmentIDs: [UUID: UUID] = [:]
    private var provisioningTasks: [UUID: Task<Void, Never>] = [:]
    private var isShuttingDown = false

    var onStateChanged: ((BorrowedZellijSessionHandle, ConnectionState) -> Void)?
    var onSurfaceReady: ((BorrowedZellijSessionHandle) -> Void)?

    init(
        terminalCoordinator: any NativeSessionSurfaceStoring,
        zellijPathProvider: @escaping @Sendable (CommandHost, [String])
            -> Result<String, ZellijCommandError> = {
                ZellijInventoryClient().resolveExecutable(
                    on: $0,
                    sshConnectionArguments: $1
                )
            },
        remoteConnectionProvider:
        @escaping @Sendable (UUID, SSHHostInfo) async throws
            -> KwtSSHConnection = { _, _ in
                throw KwtSSHLeaseError.helperUnavailable
            },
        remoteExitStatusDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-zellij-exit-\(UUID().uuidString)",
                isDirectory: true
            )
    ) {
        self.terminalCoordinator = terminalCoordinator
        self.zellijPathProvider = zellijPathProvider
        self.remoteConnectionProvider = remoteConnectionProvider
        remoteExitStatusStore = RemoteExitStatusStore(
            directory: remoteExitStatusDirectory
        )
    }

    func attach(
        hostID: UUID,
        name: String,
        host: CommandHost,
        launchMode: ZellijAttachmentLaunchMode = .attachExisting,
        sshConnectionSnapshot: SSHConnectionArgumentsSnapshot? = nil,
        resolvedZellijPath: String? = nil
    ) -> BorrowedZellijSessionHandle {
        let key = NativeZellijSessionKey(hostID: hostID, name: name)
        if let existing = handlesByKey[key],
           targetHostsByHandle[existing.id] != host {
            removeHandle(existing, for: key)
        }
        let handle = handlesByKey[key]
            ?? BorrowedZellijSessionHandle(
                id: UUID(),
                hostID: hostID,
                name: name,
                surfaceID: UUID()
            )
        handlesByKey[key] = handle
        targetHostsByHandle[handle.id] = host
        attachmentClosures.removeValue(forKey: handle.id)
        guard !isShuttingDown,
              attachments[handle.id] == nil,
              provisioningTasks[handle.id] == nil
        else { return handle }

        onStateChanged?(handle, .connecting)
        guard supportsAttachment(on: host) else {
            onStateChanged?(handle, .disconnected(
                reason: ZellijCommandError.unsupportedPlatform
                    .localizedDescription
            ))
            return handle
        }

        let pathProvider = zellijPathProvider
        let remoteConnectionProvider = remoteConnectionProvider
        let suppliedConnectionSnapshot = sshConnectionSnapshot
        provisioningTasks[handle.id] = Task { [weak self] in
            do {
                let sshConnection: KwtSSHConnection?
                let connection: SSHConnectionArgumentsSnapshot
                if case let .ssh(info) = host {
                    sshConnection = try await remoteConnectionProvider(
                        hostID,
                        info
                    )
                    connection = try await sshConnection?.snapshot(
                        validating: suppliedConnectionSnapshot
                    ) ?? SSHConnectionArgumentsSnapshot(
                        arguments: []
                    )
                } else if let sshConnectionSnapshot {
                    sshConnection = nil
                    connection = sshConnectionSnapshot
                } else {
                    sshConnection = nil
                    connection = SSHConnectionArgumentsSnapshot(arguments: [])
                }
                let probe = Task.detached(priority: .userInitiated) {
                    resolvedZellijPath.map(Result.success)
                        ?? pathProvider(host, connection.arguments)
                }
                let resolution = await withTaskCancellationHandler {
                    await probe.value
                } onCancel: {
                    probe.cancel()
                }
                self?.finishAttach(
                    handle: handle,
                    host: host,
                    launchMode: launchMode,
                    connection: connection,
                    sshConnection: sshConnection,
                    resolution: resolution
                )
            } catch {
                self?.finishAttachFailure(handle: handle, error: error)
            }
        }
        return handle
    }

    func retainFailedAttachment(
        hostID: UUID,
        name: String,
        host: CommandHost,
        reason: String
    ) -> BorrowedZellijSessionHandle {
        let key = NativeZellijSessionKey(hostID: hostID, name: name)
        if let existing = handlesByKey[key],
           targetHostsByHandle[existing.id] != host {
            removeHandle(existing, for: key)
        }
        let handle = handlesByKey[key]
            ?? BorrowedZellijSessionHandle(
                id: UUID(),
                hostID: hostID,
                name: name,
                surfaceID: UUID()
            )
        handlesByKey[key] = handle
        targetHostsByHandle[handle.id] = host
        attachmentClosures[handle.id] = .launchFailed
        onStateChanged?(handle, .disconnected(reason: reason))
        return handle
    }

    private func finishAttach(
        handle: BorrowedZellijSessionHandle,
        host: CommandHost,
        launchMode: ZellijAttachmentLaunchMode,
        connection: SSHConnectionArgumentsSnapshot,
        sshConnection: KwtSSHConnection?,
        resolution: Result<String, ZellijCommandError>
    ) {
        provisioningTasks.removeValue(forKey: handle.id)
        let key = sessionKey(handle)
        guard handlesByKey[key] == handle,
              targetHostsByHandle[handle.id] == host,
              attachments[handle.id] == nil
        else {
            Task { try? await sshConnection?.release() }
            return
        }
        switch resolution {
        case let .success(path):
            attachments[handle.id] = NativeZellijAttachment(
                id: UUID(),
                host: host,
                zellijPath: path,
                launchMode: launchMode,
                sshConnectionSnapshot: connection,
                sshConnection: sshConnection,
                remoteExitStatusURL: host.isRemote
                    ? remoteExitStatusStore.prepare() : nil
            )
            onSurfaceReady?(handle)
        case let .failure(error):
            Task {
                if case let .commandFailed(status, stderr) = error,
                   SSHConnectionFailure.indicatesUnusableConnection(
                       status: status,
                       output: stderr
                   ) {
                    await sshConnection?.invalidate()
                }
                try? await sshConnection?.release()
            }
            attachmentClosures[handle.id] = .launchFailed
            onStateChanged?(handle, .disconnected(
                reason: error.localizedDescription
            ))
        }
    }

    private func finishAttachFailure(
        handle: BorrowedZellijSessionHandle,
        error: Error
    ) {
        provisioningTasks.removeValue(forKey: handle.id)
        guard handlesByKey[sessionKey(handle)] == handle else { return }
        attachmentClosures[handle.id] = .launchFailed
        onStateChanged?(handle, .disconnected(
            reason: error.localizedDescription
        ))
    }

    func detach(hostID: UUID, name: String) {
        let key = NativeZellijSessionKey(hostID: hostID, name: name)
        guard let handle = handlesByKey.removeValue(forKey: key) else { return }
        removeHandle(handle, for: key, keyAlreadyRemoved: true)
    }

    @discardableResult
    func detachAll(hostID: UUID) -> [BorrowedZellijSessionHandle] {
        let entries = handlesByKey.filter { $0.key.hostID == hostID }
        for (key, handle) in entries {
            removeHandle(handle, for: key)
        }
        return entries.map(\.value)
    }

    private func removeHandle(
        _ handle: BorrowedZellijSessionHandle,
        for key: NativeZellijSessionKey,
        keyAlreadyRemoved: Bool = false
    ) {
        if !keyAlreadyRemoved {
            handlesByKey.removeValue(forKey: key)
        }
        provisioningTasks.removeValue(forKey: handle.id)?.cancel()
        targetHostsByHandle.removeValue(forKey: handle.id)
        let attachment = attachments.removeValue(forKey: handle.id)
        remoteExitStatusStore.remove(attachment?.remoteExitStatusURL)
        Task { try? await attachment?.sshConnection?.release() }
        attachmentClosures.removeValue(forKey: handle.id)
        launchedHandles.remove(handle.id)
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
    }

    func attachmentClosure(
        _ handle: BorrowedZellijSessionHandle
    ) -> BorrowedZellijAttachmentClosure? {
        attachmentClosures[handle.id]
    }

    func hasLaunched(_ handle: BorrowedZellijSessionHandle) -> Bool {
        launchedHandles.contains(handle.id)
    }

    func attachmentConnectionSnapshot(
        _ handle: BorrowedZellijSessionHandle
    ) -> SSHConnectionArgumentsSnapshot? {
        attachments[handle.id]?.sshConnectionSnapshot
    }

    func surface(handle: BorrowedZellijSessionHandle) -> TerminalSurfaceView? {
        guard attachmentClosures[handle.id] == nil,
              let attachment = attachments[handle.id]
        else { return nil }
        let command: String
        do {
            command = try ZellijAttachmentInfo(
                sessionName: handle.name,
                host: attachment.host
            ).attachCommand(
                zellijPath: attachment.zellijPath,
                launchMode: attachment.launchMode,
                sshConnectionArguments:
                attachment.sshConnectionSnapshot.arguments,
                remoteExitStatusPath: attachment.remoteExitStatusURL?.path
            )
        } catch {
            failSurfaceLaunch(handle, reason: error.localizedDescription)
            return nil
        }
        let surface = terminalCoordinator.paneSurface(
            for: surfaceKey(handle),
            configuration: TerminalSurfaceConfiguration(
                workingDirectory: NSHomeDirectory(),
                command: command
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
        _ handle: BorrowedZellijSessionHandle,
        reason: String,
        closure: BorrowedZellijAttachmentClosure = .launchFailed
    ) {
        AppLogger.shared.error(
            "zellij surface launch failed: \(reason) "
                + "retryable=\(closure == .surfaceUnavailable) "
                + "activeDisplays=\(DisplayAvailability.activeCount())",
            context: "zellij"
        )
        attachmentClosures[handle.id] = closure
        let attachment = attachments.removeValue(forKey: handle.id)
        remoteExitStatusStore.remove(attachment?.remoteExitStatusURL)
        Task { try? await attachment?.sshConnection?.release() }
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
        reportSurfaceStateLater(handle, state: .disconnected(reason: reason))
    }

    private func reportSurfaceStateLater(
        _ handle: BorrowedZellijSessionHandle,
        state: ConnectionState,
        requiredAttachmentID: UUID? = nil
    ) {
        Task { [weak self] in
            guard let self, !isShuttingDown,
                  handlesByKey[sessionKey(handle)] == handle
            else { return }
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
        _ handle: BorrowedZellijSessionHandle,
        processAlive: Bool,
        childExitCode: UInt32?
    ) {
        guard handlesByKey[sessionKey(handle)] == handle else { return }
        let attachment = attachments.removeValue(forKey: handle.id)
        let recordedExitCode = remoteExitStatusStore.consume(
            attachment?.remoteExitStatusURL
        )
        if let recordedExitCode {
            attachmentClosures[handle.id] = recordedExitCode == 0
                ? .detached : .processExited(code: recordedExitCode)
        } else {
            attachmentClosures[handle.id] = processAlive || childExitCode == 0
                ? .detached : .processExited(code: childExitCode)
        }
        let connectionUnusable = SSHConnectionFailure
            .presentationConnectionUnusable(
                recordedExitCode: recordedExitCode,
                childExitCode: childExitCode
            )
        Task {
            if connectionUnusable {
                await attachment?.sshConnection?.invalidate()
            }
            try? await attachment?.sshConnection?.release()
        }
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
        onStateChanged?(handle, .disconnected(
            reason: "The Zellij attachment to “\(handle.name)” closed."
        ))
    }

    func shutdown() async {
        isShuttingDown = true
        let handles = Array(handlesByKey.values)
        let connections = attachments.values.compactMap(\.sshConnection)
        provisioningTasks.values.forEach { $0.cancel() }
        provisioningTasks.removeAll()
        handlesByKey.removeAll()
        targetHostsByHandle.removeAll()
        for attachment in attachments.values {
            remoteExitStatusStore.remove(attachment.remoteExitStatusURL)
        }
        attachments.removeAll()
        attachmentClosures.removeAll()
        launchedHandles.removeAll()
        reportedConnectedAttachmentIDs.removeAll()
        for handle in handles {
            terminalCoordinator.removeSurface(for: surfaceKey(handle))
        }
        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                group.addTask { try? await connection.release() }
            }
        }
    }

    private func supportsAttachment(on host: CommandHost) -> Bool {
        switch host {
        case .local:
            true
        case let .ssh(info):
            info.platform == .posix
        }
    }

    private func surfaceKey(_ handle: BorrowedZellijSessionHandle) -> SurfaceKey {
        SurfaceKey(
            worktreeID: handle.id,
            hostID: handle.hostID,
            target: .zellijSession,
            leafID: handle.surfaceID
        )
    }

    private func sessionKey(
        _ handle: BorrowedZellijSessionHandle
    ) -> NativeZellijSessionKey {
        NativeZellijSessionKey(hostID: handle.hostID, name: handle.name)
    }
}
