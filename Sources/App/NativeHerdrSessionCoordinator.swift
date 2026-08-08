import Foundation
import GhosthubHerdr
import GhosthubTerminal
import GhosthubTransport
import GhosthubWorkspace

struct BorrowedHerdrSessionHandle: Equatable, Sendable {
    var id: UUID
    var hostID: UUID
    var name: String
    var surfaceID: UUID
}

enum BorrowedHerdrAttachmentClosure: Equatable {
    case detached
    case processExited(code: UInt32?)
    case launchFailed
}

private struct NativeHerdrSessionKey: Hashable {
    var hostID: UUID
    var name: String
}

private struct NativeHerdrAttachment {
    var id: UUID
    var host: CommandHost
    var herdrPath: String
    var launchMode: HerdrAttachmentLaunchMode
    var sshConnectionArguments: [String]
    var remoteExitStatusURL: URL?
}

/// Hosts disposable Herdr clients. Herdr owns the server, processes, tabs,
/// panes, history, and keybindings; this coordinator owns only presentation.
@MainActor
final class NativeHerdrSessionCoordinator {
    private let terminalCoordinator: any NativeSessionSurfaceStoring
    private let herdrPathProvider:
        @Sendable (CommandHost) -> Result<String, HerdrCommandError>
    private let sshConnectionArgumentsProvider:
        @Sendable (SSHHostInfo) -> [String]
    private let remoteExitStatusStore: RemoteExitStatusStore
    private var handlesByKey: [
        NativeHerdrSessionKey: BorrowedHerdrSessionHandle
    ] = [:]
    private var targetHostsByHandle: [UUID: CommandHost] = [:]
    private var attachments: [UUID: NativeHerdrAttachment] = [:]
    private var attachmentClosures: [
        UUID: BorrowedHerdrAttachmentClosure
    ] = [:]
    private var launchedHandles: Set<UUID> = []
    private var reportedConnectedAttachmentIDs: [UUID: UUID] = [:]
    private var herdrPathsByHost: [CommandHost: String] = [:]
    private var provisioningHandles: Set<UUID> = []
    private var provisioningTasks: [UUID: Task<Void, Never>] = [:]
    private var isShuttingDown = false

    var onStateChanged: ((BorrowedHerdrSessionHandle, ConnectionState) -> Void)?
    var onSurfaceReady: ((BorrowedHerdrSessionHandle) -> Void)?

    init(
        terminalCoordinator: any NativeSessionSurfaceStoring,
        herdrPathProvider: @escaping @Sendable (CommandHost)
            -> Result<String, HerdrCommandError> = {
                HerdrInventoryClient().resolveExecutable(on: $0)
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
                "ghosthub-herdr-exit-\(UUID().uuidString)",
                isDirectory: true
            )
    ) {
        self.terminalCoordinator = terminalCoordinator
        self.herdrPathProvider = herdrPathProvider
        self.sshConnectionArgumentsProvider =
            sshConnectionArgumentsProvider
        remoteExitStatusStore = RemoteExitStatusStore(
            directory: remoteExitStatusDirectory
        )
    }

    func attach(
        hostID: UUID,
        name: String,
        host: CommandHost,
        launchMode: HerdrAttachmentLaunchMode = .attachExisting
    ) -> BorrowedHerdrSessionHandle {
        let key = NativeHerdrSessionKey(hostID: hostID, name: name)
        if let existing = handlesByKey[key],
           targetHostsByHandle[existing.id] != host {
            removeHandle(existing, for: key)
        }
        let handle = handlesByKey[key]
            ?? BorrowedHerdrSessionHandle(
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
              !provisioningHandles.contains(handle.id)
        else { return handle }

        onStateChanged?(handle, .connecting)
        guard supportsAttachment(on: host) else {
            onStateChanged?(
                handle,
                .disconnected(
                    reason: HerdrCommandError.unsupportedPlatform
                        .localizedDescription
                )
            )
            return handle
        }

        provisioningHandles.insert(handle.id)
        let cachedPath = herdrPathsByHost[host]
        let herdrPathProvider = herdrPathProvider
        let sshConnectionArgumentsProvider =
            sshConnectionArgumentsProvider
        provisioningTasks[handle.id] = Task { [weak self] in
            let probe = Task.detached(priority: .userInitiated) {
                let resolution = cachedPath.map(Result.success)
                    ?? herdrPathProvider(host)
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
                launchMode: launchMode,
                sshConnectionArguments: sshConnectionArguments,
                resolution: resolution
            )
        }
        return handle
    }

    private func finishAttach(
        handle: BorrowedHerdrSessionHandle,
        host: CommandHost,
        launchMode: HerdrAttachmentLaunchMode,
        sshConnectionArguments: [String],
        resolution: Result<String, HerdrCommandError>
    ) {
        provisioningTasks.removeValue(forKey: handle.id)
        provisioningHandles.remove(handle.id)
        let key = sessionKey(handle)
        guard handlesByKey[key] == handle,
              targetHostsByHandle[handle.id] == host,
              attachments[handle.id] == nil
        else { return }

        switch resolution {
        case let .success(path):
            herdrPathsByHost[host] = path
            attachments[handle.id] = NativeHerdrAttachment(
                id: UUID(),
                host: host,
                herdrPath: path,
                launchMode: launchMode,
                sshConnectionArguments: sshConnectionArguments,
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

    func detach(hostID: UUID, name: String) {
        let key = NativeHerdrSessionKey(hostID: hostID, name: name)
        guard let handle = handlesByKey.removeValue(forKey: key) else {
            return
        }
        removeHandle(handle, for: key, keyAlreadyRemoved: true)
    }

    @discardableResult
    func detachAll(hostID: UUID) -> [BorrowedHerdrSessionHandle] {
        let entries = handlesByKey.filter { $0.key.hostID == hostID }
        for (key, handle) in entries {
            removeHandle(handle, for: key)
        }
        return entries.map(\.value)
    }

    private func removeHandle(
        _ handle: BorrowedHerdrSessionHandle,
        for key: NativeHerdrSessionKey,
        keyAlreadyRemoved: Bool = false
    ) {
        if !keyAlreadyRemoved {
            handlesByKey.removeValue(forKey: key)
        }
        provisioningTasks.removeValue(forKey: handle.id)?.cancel()
        provisioningHandles.remove(handle.id)
        targetHostsByHandle.removeValue(forKey: handle.id)
        remoteExitStatusStore.remove(
            attachments.removeValue(forKey: handle.id)?.remoteExitStatusURL
        )
        attachmentClosures.removeValue(forKey: handle.id)
        launchedHandles.remove(handle.id)
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
    }

    func hasLaunched(_ handle: BorrowedHerdrSessionHandle) -> Bool {
        launchedHandles.contains(handle.id)
    }

    func attachmentClosure(
        _ handle: BorrowedHerdrSessionHandle
    ) -> BorrowedHerdrAttachmentClosure? {
        attachmentClosures[handle.id]
    }

    func surface(handle: BorrowedHerdrSessionHandle) -> TerminalSurfaceView? {
        guard attachmentClosures[handle.id] == nil,
              let attachment = attachments[handle.id]
        else { return nil }
        let command: String
        do {
            command = try HerdrAttachmentInfo(
                sessionName: handle.name,
                host: attachment.host
            ).attachCommand(
                herdrPath: attachment.herdrPath,
                launchMode: attachment.launchMode,
                sshConnectionArguments:
                attachment.sshConnectionArguments,
                remoteExitStatusPath:
                attachment.remoteExitStatusURL?.path
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
            failSurfaceLaunch(handle, reason: error.localizedDescription)
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
        _ handle: BorrowedHerdrSessionHandle,
        reason: String
    ) {
        attachmentClosures[handle.id] = .launchFailed
        remoteExitStatusStore.remove(
            attachments.removeValue(forKey: handle.id)?.remoteExitStatusURL
        )
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
        reportSurfaceStateLater(
            handle,
            state: .disconnected(reason: reason)
        )
    }

    func surfaceIdentity(handle: BorrowedHerdrSessionHandle) -> UInt? {
        terminalCoordinator.surfaceIdentity(for: surfaceKey(handle))
    }

    private func reportSurfaceStateLater(
        _ handle: BorrowedHerdrSessionHandle,
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
        _ handle: BorrowedHerdrSessionHandle,
        processAlive: Bool,
        childExitCode: UInt32?
    ) {
        let key = sessionKey(handle)
        guard handlesByKey[key] == handle else { return }
        let attachment = attachments.removeValue(forKey: handle.id)
        let recordedExitCode = remoteExitStatusStore.consume(
            attachment?.remoteExitStatusURL
        )
        let exitCode = recordedExitCode ?? childExitCode
        // As with tmux, SSH 255 is treated as transport loss. If a future
        // Herdr client uses 255 itself, the recovery probe will stop retries
        // once it observes that this exact session is no longer running.
        if processAlive || exitCode == 0 {
            attachmentClosures[handle.id] = .detached
        } else {
            attachmentClosures[handle.id] = .processExited(code: exitCode)
        }
        reportedConnectedAttachmentIDs.removeValue(forKey: handle.id)
        terminalCoordinator.removeSurface(for: surfaceKey(handle))
        onStateChanged?(
            handle,
            .disconnected(
                reason: "The Herdr attachment to “\(handle.name)” closed."
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
        for value in attachments.values {
            remoteExitStatusStore.remove(value.remoteExitStatusURL)
        }
        attachments.removeAll()
        attachmentClosures.removeAll()
        launchedHandles.removeAll()
        reportedConnectedAttachmentIDs.removeAll()
        for handle in handles {
            terminalCoordinator.removeSurface(for: surfaceKey(handle))
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

    private func surfaceKey(
        _ handle: BorrowedHerdrSessionHandle
    ) -> SurfaceKey {
        SurfaceKey(
            worktreeID: handle.id,
            hostID: handle.hostID,
            target: .herdrSession,
            leafID: handle.surfaceID
        )
    }

    private func sessionKey(
        _ handle: BorrowedHerdrSessionHandle
    ) -> NativeHerdrSessionKey {
        NativeHerdrSessionKey(hostID: handle.hostID, name: handle.name)
    }
}
