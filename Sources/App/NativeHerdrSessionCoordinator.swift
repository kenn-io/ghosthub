import Foundation
import GhosthubHerdr
import GhosthubTerminal
import GhosthubTerminalSupport
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
    var sshConnectionSnapshot: SSHConnectionArgumentsSnapshot
    var paneSplitTarget: HerdrPaneSplitTarget?
    var remoteExitStatusURL: URL?
}

/// Hosts disposable Herdr clients. Herdr owns the server, processes, tabs,
/// panes, history, and keybindings; this coordinator owns only presentation.
@MainActor
final class NativeHerdrSessionCoordinator {
    typealias PaneSplitCapabilityProvider = @Sendable (
        CommandHost,
        [String],
        String,
        String
    ) -> Result<HerdrPaneSplitCapability?, HerdrCommandError>

    private struct PaneSplitRequest {
        var shortcut: TerminalPaneSplitShortcut
        var target: HerdrPaneSplitTarget
        var surface: any NativeSessionPaneSurfacing
        var attachmentID: UUID
    }

    private struct PaneSplitWorker {
        var id: UUID
        var task: Task<Void, Never>
    }

    private struct PaneSplitCapabilityTask {
        var id: UUID
        var task: Task<Void, Never>
    }

    private let terminalCoordinator: any NativeSessionSurfaceStoring
    private let herdrPathProvider:
        @Sendable (CommandHost, [String]) -> Result<String, HerdrCommandError>
    private let sshConnectionArgumentsProvider:
        @Sendable (SSHHostInfo) -> SSHConnectionArgumentsSnapshot
    private let paneSplitCapabilityProvider: PaneSplitCapabilityProvider
    private let paneSplitter: HerdrPaneSplitter
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
    private var provisioningHandles: Set<UUID> = []
    private var provisioningTasks: [UUID: Task<Void, Never>] = [:]
    private var paneSplitCapabilityTasks: [
        UUID: PaneSplitCapabilityTask
    ] = [:]
    private var paneSplitRequests: [UUID: [PaneSplitRequest]] = [:]
    private var paneSplitWorkers: [UUID: PaneSplitWorker] = [:]
    private var isShuttingDown = false

    var onStateChanged: ((BorrowedHerdrSessionHandle, ConnectionState) -> Void)?
    var onSurfaceReady: ((BorrowedHerdrSessionHandle) -> Void)?

    init(
        terminalCoordinator: any NativeSessionSurfaceStoring,
        herdrPathProvider: @escaping @Sendable (CommandHost, [String])
            -> Result<String, HerdrCommandError> = {
                HerdrInventoryClient().resolveExecutable(
                    on: $0,
                    sshConnectionArguments: $1
                )
            },
        sshConnectionArgumentsProvider:
        @escaping @Sendable (SSHHostInfo)
            -> SSHConnectionArgumentsSnapshot = {
                SSHCommandArguments.connectionSnapshot(for: $0)
            },
        paneSplitCapabilityProvider:
        @escaping PaneSplitCapabilityProvider = {
            host, arguments, path, name in
            HerdrInventoryClient().paneSplitCapability(
                on: host,
                herdrPath: path,
                sessionName: name,
                sshConnectionArguments: arguments
            )
        },
        paneSplitter: HerdrPaneSplitter = HerdrPaneSplitter(),
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
        self.paneSplitCapabilityProvider = paneSplitCapabilityProvider
        self.paneSplitter = paneSplitter
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
        let herdrPathProvider = herdrPathProvider
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
                let resolution = herdrPathProvider(
                    host,
                    sshConnectionSnapshot.arguments
                )
                return (resolution, sshConnectionSnapshot)
            }
            let (resolution, sshConnectionSnapshot) =
                await withTaskCancellationHandler {
                    await probe.value
                } onCancel: {
                    probe.cancel()
                }
            self?.finishAttach(
                handle: handle,
                host: host,
                launchMode: launchMode,
                sshConnectionSnapshot: sshConnectionSnapshot,
                resolution: resolution
            )
        }
        return handle
    }

    private func finishAttach(
        handle: BorrowedHerdrSessionHandle,
        host: CommandHost,
        launchMode: HerdrAttachmentLaunchMode,
        sshConnectionSnapshot: SSHConnectionArgumentsSnapshot,
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
            attachments[handle.id] = NativeHerdrAttachment(
                id: UUID(),
                host: host,
                herdrPath: path,
                launchMode: launchMode,
                sshConnectionSnapshot: sshConnectionSnapshot,
                paneSplitTarget: nil,
                remoteExitStatusURL: host.isRemote
                    ? remoteExitStatusStore.prepare()
                    : nil
            )
            startPaneSplitCapabilityBinding(handle)
            onSurfaceReady?(handle)
        case let .failure(error):
            attachmentClosures[handle.id] = .launchFailed
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
        cancelPaneSplits(handleID: handle.id)
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
                attachment.sshConnectionSnapshot.arguments,
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
        if let target = attachment.paneSplitTarget {
            installPaneSplitHandler(
                on: surface,
                target: target,
                handle: handle,
                attachmentID: attachment.id
            )
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
        cancelPaneSplits(handleID: handle.id)
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

    func supportsPaneSplitting(_ handle: BorrowedHerdrSessionHandle) -> Bool {
        attachments[handle.id]?.paneSplitTarget != nil
    }

    func requestPaneSplit(
        _ shortcut: TerminalPaneSplitShortcut,
        handle: BorrowedHerdrSessionHandle,
        requiresKeyboardFocus: Bool
    ) {
        guard let surface = terminalCoordinator.paneSurfaceIfPresent(
            for: surfaceKey(handle)
        ),
            !requiresKeyboardFocus || surface.hasEffectiveKeyboardFocus
        else { return }
        surface.paneSplitShortcutHandler?(shortcut)
    }

    func refreshPaneSplitCapability(
        _ handle: BorrowedHerdrSessionHandle
    ) {
        startPaneSplitCapabilityBinding(handle)
    }

    private func startPaneSplitCapabilityBinding(
        _ handle: BorrowedHerdrSessionHandle
    ) {
        guard let attachment = attachments[handle.id] else { return }
        paneSplitCapabilityTasks.removeValue(forKey: handle.id)?.task.cancel()
        let bindingID = UUID()
        let provider = paneSplitCapabilityProvider
        let task = Task { [weak self] in
            let probe = Task.detached(priority: .userInitiated) {
                provider(
                    attachment.host,
                    attachment.sshConnectionSnapshot.arguments,
                    attachment.herdrPath,
                    handle.name
                )
            }
            let result = await withTaskCancellationHandler {
                await probe.value
            } onCancel: {
                probe.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  paneSplitCapabilityTasks[handle.id]?.id == bindingID,
                  attachments[handle.id]?.id == attachment.id
            else { return }
            paneSplitCapabilityTasks.removeValue(forKey: handle.id)
            let capability: HerdrPaneSplitCapability?
            if case let .success(value) = result {
                capability = value
            } else {
                capability = nil
            }
            let target = capability.map {
                HerdrPaneSplitTarget(
                    host: attachment.host,
                    herdrPath: attachment.herdrPath,
                    sessionName: handle.name,
                    socketPath: $0.session.socketPath,
                    sshConnectionArguments:
                    attachment.sshConnectionSnapshot.arguments
                )
            }
            attachments[handle.id]?.paneSplitTarget = target
            if let surface = terminalCoordinator.paneSurfaceIfPresent(
                for: surfaceKey(handle)
            ) {
                surface.paneSplitShortcutHandler = nil
                if let target {
                    installPaneSplitHandler(
                        on: surface,
                        target: target,
                        handle: handle,
                        attachmentID: attachment.id
                    )
                }
            }
            onSurfaceReady?(handle)
        }
        paneSplitCapabilityTasks[handle.id] = PaneSplitCapabilityTask(
            id: bindingID,
            task: task
        )
    }

    private func installPaneSplitHandler(
        on surface: any NativeSessionPaneSurfacing,
        target: HerdrPaneSplitTarget,
        handle: BorrowedHerdrSessionHandle,
        attachmentID: UUID
    ) {
        surface.paneSplitShortcutHandler = {
            [weak self, weak surface] shortcut in
            guard let self, let surface else { return }
            enqueuePaneSplit(
                shortcut,
                target: target,
                surface: surface,
                handle: handle,
                attachmentID: attachmentID
            )
        }
    }

    private func enqueuePaneSplit(
        _ shortcut: TerminalPaneSplitShortcut,
        target: HerdrPaneSplitTarget,
        surface: any NativeSessionPaneSurfacing,
        handle: BorrowedHerdrSessionHandle,
        attachmentID: UUID
    ) {
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
            await runPaneSplitQueue(handle: handle, workerID: workerID)
        }
        paneSplitWorkers[handle.id] = PaneSplitWorker(
            id: workerID,
            task: task
        )
    }

    private func runPaneSplitQueue(
        handle: BorrowedHerdrSessionHandle,
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
            request.surface.paneSplitErrorMessage = nil
            let failure = await paneSplitter.split(
                request.shortcut,
                target: request.target
            )
            guard !Task.isCancelled,
                  paneSplitWorkers[handle.id]?.id == workerID,
                  attachments[handle.id]?.id == request.attachmentID
            else { return }
            request.surface.paneSplitErrorMessage = failure?.localizedDescription
            if let failure {
                AppLogger.shared.error(
                    "Herdr pane split: \(failure.localizedDescription)"
                )
            }
        }
    }

    private func cancelPaneSplits(handleID: UUID) {
        paneSplitCapabilityTasks.removeValue(
            forKey: handleID
        )?.task.cancel()
        paneSplitWorkers.removeValue(forKey: handleID)?.task.cancel()
        paneSplitRequests.removeValue(forKey: handleID)
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
        cancelPaneSplits(handleID: handle.id)
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
        paneSplitCapabilityTasks.values.forEach { $0.task.cancel() }
        paneSplitCapabilityTasks.removeAll()
        paneSplitWorkers.values.forEach { $0.task.cancel() }
        paneSplitWorkers.removeAll()
        paneSplitRequests.removeAll()
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
