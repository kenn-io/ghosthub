import Foundation
import GhosthubBackendTerminal
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubTransport
import GhosthubWorkspace

struct BorrowedBackendTerminalHandle: Equatable, Sendable {
    var id: UUID
    var selection: WorkspaceBackendTerminalSelection
    var surfaceID: UUID

    var hostID: UUID { selection.hostID }
}

private struct NativeBackendTerminalAttachment {
    var id: UUID
    var host: CommandHost
    var executablePath: String
    var sshConnectionSnapshot: SSHConnectionArgumentsSnapshot
    var sshConnection: KwtSSHConnection?
    var remoteExitStatusURL: URL?
}

/// Hosts disposable attach clients for backend terminals (Herdr Core and
/// Rex). The backend owns each terminal's program, lifetime, and layout;
/// closing a surface only detaches.
@MainActor
final class NativeBackendTerminalCoordinator {
    typealias ExecutableProvider = @Sendable (
        BackendTerminalKind, CommandHost, [String]
    ) -> Result<String, BackendTerminalCommandError>

    private let terminalCoordinator: any NativeSessionSurfaceStoring
    private let executableProvider: ExecutableProvider
    private let remoteConnectionProvider:
        @Sendable (UUID, SSHHostInfo) async throws -> KwtSSHConnection
    private let remoteExitStatusStore: RemoteExitStatusStore
    private var handlesBySelection: [
        WorkspaceBackendTerminalSelection: BorrowedBackendTerminalHandle
    ] = [:]
    private var targetHostsByHandle: [UUID: CommandHost] = [:]
    private var attachments: [UUID: NativeBackendTerminalAttachment] = [:]
    private var attachmentClosures: [UUID: BorrowedSessionAttachmentClosure] = [:]
    private var launchedHandles: Set<UUID> = []
    private var reportedConnectedAttachmentIDs: [UUID: UUID] = [:]
    private var keyboardSuspendedHandles: Set<UUID> = []
    private var provisioningTasks: [UUID: Task<Void, Never>] = [:]
    private var isShuttingDown = false

    var onStateChanged: ((BorrowedBackendTerminalHandle, ConnectionState) -> Void)?
    var onSurfaceReady: ((BorrowedBackendTerminalHandle) -> Void)?

    init(
        terminalCoordinator: any NativeSessionSurfaceStoring,
        executableProvider: @escaping ExecutableProvider = { kind, host, arguments in
            BackendTerminalInventoryClient().resolveExecutable(
                kind, on: host, sshConnectionArguments: arguments
            )
        },
        remoteConnectionProvider:
        @escaping @Sendable (UUID, SSHHostInfo) async throws
            -> KwtSSHConnection = { _, _ in
                throw KwtSSHLeaseError.helperUnavailable
            },
        remoteExitStatusDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-terminal-exit-\(UUID().uuidString)",
                isDirectory: true
            )
    ) {
        self.terminalCoordinator = terminalCoordinator
        self.executableProvider = executableProvider
        self.remoteConnectionProvider = remoteConnectionProvider
        remoteExitStatusStore = RemoteExitStatusStore(
            directory: remoteExitStatusDirectory
        )
    }

    /// Starts an attach client. `validated` is the SSH connection that
    /// confirmed the terminal exists; the attach refuses a different route,
    /// so a changed SSH alias cannot reach a same-named terminal elsewhere.
    func attach(
        _ selection: WorkspaceBackendTerminalSelection,
        host: CommandHost,
        validated: SSHConnectionArgumentsSnapshot? = nil
    ) -> BorrowedBackendTerminalHandle {
        if let existing = handlesBySelection[selection],
           targetHostsByHandle[existing.id] != host {
            removeHandle(existing)
        }
        let handle = handlesBySelection[selection]
            ?? BorrowedBackendTerminalHandle(
                id: UUID(),
                selection: selection,
                surfaceID: UUID()
            )
        handlesBySelection[selection] = handle
        targetHostsByHandle[handle.id] = host
        attachmentClosures.removeValue(forKey: handle.id)
        guard !isShuttingDown,
              attachments[handle.id] == nil,
              provisioningTasks[handle.id] == nil
        else { return handle }

        onStateChanged?(handle, .connecting)
        guard BackendTerminalInventoryClient.supports(host) else {
            attachmentClosures[handle.id] = .launchFailed
            onStateChanged?(handle, .disconnected(
                reason: BackendTerminalCommandError
                    .unsupportedPlatform(selection.kind).localizedDescription
            ))
            return handle
        }

        let executableProvider = executableProvider
        let remoteConnectionProvider = remoteConnectionProvider
        provisioningTasks[handle.id] = Task { [weak self] in
            do {
                let sshConnection: KwtSSHConnection?
                let connection: SSHConnectionArgumentsSnapshot
                if case let .ssh(info) = host {
                    sshConnection = try await remoteConnectionProvider(
                        selection.hostID,
                        info
                    )
                    connection = try await sshConnection?.snapshot(validating: validated)
                        ?? SSHConnectionArgumentsSnapshot(arguments: [])
                } else {
                    sshConnection = nil
                    connection = SSHConnectionArgumentsSnapshot(arguments: [])
                }
                let probe = Task.detached(priority: .userInitiated) {
                    executableProvider(selection.kind, host, connection.arguments)
                }
                let resolution = await withTaskCancellationHandler {
                    await probe.value
                } onCancel: {
                    probe.cancel()
                }
                self?.finishAttach(
                    handle: handle,
                    host: host,
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

    private func finishAttach(
        handle: BorrowedBackendTerminalHandle,
        host: CommandHost,
        connection: SSHConnectionArgumentsSnapshot,
        sshConnection: KwtSSHConnection?,
        resolution: Result<String, BackendTerminalCommandError>
    ) {
        provisioningTasks.removeValue(forKey: handle.id)
        guard handlesBySelection[handle.selection] == handle,
              targetHostsByHandle[handle.id] == host,
              attachments[handle.id] == nil
        else {
            Task { try? await sshConnection?.release() }
            return
        }
        switch resolution {
        case let .success(path):
            attachments[handle.id] = NativeBackendTerminalAttachment(
                id: UUID(),
                host: host,
                executablePath: path,
                sshConnectionSnapshot: connection,
                sshConnection: sshConnection,
                remoteExitStatusURL: host.isRemote
                    ? remoteExitStatusStore.prepare() : nil
            )
            onSurfaceReady?(handle)
        case let .failure(error):
            Task {
                if case let .commandFailed(_, status, stderr) = error,
                   SSHConnectionFailure.indicatesUnusableConnection(
                       status: status,
                       output: stderr
                   ) {
                    await sshConnection?.invalidate()
                }
                try? await sshConnection?.release()
            }
            // A connection that dropped during the lookup recovers like any
            // other transport failure. A missing program does not.
            if host.isRemote, case let .commandFailed(_, status, stderr) = error,
               status == 255,
               SSHConnectionFailure.classify(status: status, output: stderr).kind
               == .transport {
                attachmentClosures[handle.id] = .retryableTransportFailure
            } else {
                attachmentClosures[handle.id] = .launchFailed
            }
            onStateChanged?(handle, .disconnected(
                reason: error.localizedDescription
            ))
        }
    }

    private func finishAttachFailure(
        handle: BorrowedBackendTerminalHandle,
        error: Error
    ) {
        provisioningTasks.removeValue(forKey: handle.id)
        guard handlesBySelection[handle.selection] == handle else { return }
        if case KwtSSHLeaseError.routeChanged = error {
            attachmentClosures[handle.id] = .launchFailed
            onStateChanged?(handle, .disconnected(
                reason: Self.routeChangedReason
            ))
            return
        }
        attachmentClosures[handle.id] =
            SSHConnectionFailure.retryableTransportFailure(error) == nil
                ? .launchFailed
                : .retryableTransportFailure
        onStateChanged?(handle, .disconnected(
            reason: error.localizedDescription
        ))
    }

    nonisolated static let routeChangedReason =
        "The SSH connection changed since Ghosthub found this terminal. "
            + "Reopen it from the sidebar to use the current connection."

    func detach(_ selection: WorkspaceBackendTerminalSelection) {
        guard let handle = handlesBySelection[selection] else { return }
        removeHandle(handle)
    }

    @discardableResult
    func detachAll(hostID: UUID) -> [BorrowedBackendTerminalHandle] {
        let handles = handlesBySelection.values.filter { $0.hostID == hostID }
        handles.forEach(removeHandle)
        return handles
    }

    private func removeHandle(_ handle: BorrowedBackendTerminalHandle) {
        handlesBySelection.removeValue(forKey: handle.selection)
        provisioningTasks.removeValue(forKey: handle.id)?.cancel()
        targetHostsByHandle.removeValue(forKey: handle.id)
        let attachment = attachments.removeValue(forKey: handle.id)
        remoteExitStatusStore.remove(attachment?.remoteExitStatusURL)
        Task { try? await attachment?.sshConnection?.release() }
        attachmentClosures.removeValue(forKey: handle.id)
        launchedHandles.remove(handle.id)
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
        keyboardSuspendedHandles.remove(handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
    }

    func requestKeyboardFocus(handle: BorrowedBackendTerminalHandle) {
        terminalCoordinator.paneSurfaceIfPresent(for: surfaceKey(handle))?
            .requestKeyboardFocus()
    }

    /// Keeps a terminal on screen but stops it taking keystrokes, such as
    /// while Ghosthub checks the terminal that will replace it.
    func setKeyboardInteractionSuspended(
        _ suspended: Bool,
        handle: BorrowedBackendTerminalHandle
    ) {
        if suspended {
            keyboardSuspendedHandles.insert(handle.id)
        } else {
            keyboardSuspendedHandles.remove(handle.id)
        }
        let view = terminalCoordinator.paneSurfaceIfPresent(for: surfaceKey(handle))
            as? TerminalSurfaceView
        view?.isKeyboardInteractionSuspended = suspended
    }

    func attachmentClosure(
        _ handle: BorrowedBackendTerminalHandle
    ) -> BorrowedSessionAttachmentClosure? {
        attachmentClosures[handle.id]
    }

    func hasLaunched(_ handle: BorrowedBackendTerminalHandle) -> Bool {
        launchedHandles.contains(handle.id)
    }

    func surface(handle: BorrowedBackendTerminalHandle) -> TerminalSurfaceView? {
        guard attachmentClosures[handle.id] == nil,
              let attachment = attachments[handle.id]
        else { return nil }
        let command: String
        do {
            command = try BackendTerminalAttachmentInfo(
                terminal: BackendTerminalSummary(
                    kind: handle.selection.kind,
                    address: handle.selection.address
                ),
                host: attachment.host
            ).attachCommand(
                executablePath: attachment.executablePath,
                sshConnectionArguments: attachment.sshConnectionSnapshot.arguments,
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
        surface.terminalFindController = .unavailable
        (surface as? TerminalSurfaceView)?.isKeyboardInteractionSuspended =
            keyboardSuspendedHandles.contains(handle.id)
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
        _ handle: BorrowedBackendTerminalHandle,
        reason: String,
        closure: BorrowedSessionAttachmentClosure = .launchFailed
    ) {
        AppLogger.shared.error(
            "backend terminal surface launch failed: \(reason) "
                + "kind=\(handle.selection.kind.rawValue) "
                + "retryable=\(closure == .surfaceUnavailable)",
            context: "backend-terminal"
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
        _ handle: BorrowedBackendTerminalHandle,
        state: ConnectionState,
        requiredAttachmentID: UUID? = nil
    ) {
        Task { [weak self] in
            guard let self, !isShuttingDown,
                  handlesBySelection[handle.selection] == handle
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
        _ handle: BorrowedBackendTerminalHandle,
        processAlive: Bool,
        childExitCode: UInt32?
    ) {
        guard handlesBySelection[handle.selection] == handle else { return }
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
        // A clean detach needs no explanation beyond its heading.
        let reason: String? = switch attachmentClosures[handle.id] {
        case let .processExited(code?):
            "The attach client exited with status \(code)."
        default:
            nil
        }
        onStateChanged?(handle, .disconnected(reason: reason))
    }

    func shutdown() async {
        isShuttingDown = true
        let handles = Array(handlesBySelection.values)
        let connections = attachments.values.compactMap(\.sshConnection)
        provisioningTasks.values.forEach { $0.cancel() }
        provisioningTasks.removeAll()
        handlesBySelection.removeAll()
        targetHostsByHandle.removeAll()
        for attachment in attachments.values {
            remoteExitStatusStore.remove(attachment.remoteExitStatusURL)
        }
        attachments.removeAll()
        attachmentClosures.removeAll()
        launchedHandles.removeAll()
        reportedConnectedAttachmentIDs.removeAll()
        keyboardSuspendedHandles.removeAll()
        for handle in handles {
            terminalCoordinator.removeSurface(for: surfaceKey(handle))
        }
        await withTaskGroup(of: Void.self) { group in
            for connection in connections {
                group.addTask { try? await connection.release() }
            }
        }
    }

    private func surfaceKey(_ handle: BorrowedBackendTerminalHandle) -> SurfaceKey {
        SurfaceKey(
            worktreeID: handle.id,
            hostID: handle.hostID,
            target: .backendTerminal,
            leafID: handle.surfaceID
        )
    }
}
