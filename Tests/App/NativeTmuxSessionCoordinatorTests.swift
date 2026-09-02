import GhosthubTransport
import Foundation
import GhosthubTerminal
import GhosthubTestSupport
import GhosthubTmux
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

private let coordinatorSplitIdentity = TmuxSessionIdentity(
    serverPID: "123",
    sessionID: "$7",
    createdAt: "456"
)
private let coordinatorSplitClientOutput =
    "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY\t123\t789\t321"
        + "\t/dev/ttys001\t$7\t456\t%9\n"

private func supportedPaneSplitter(
    _ runner: @escaping TmuxPaneSplitter.Runner
) -> TmuxPaneSplitter {
    TmuxPaneSplitter(runner: runner)
}

private func splitMismatchMarker(in command: String) -> String? {
    let prefix = "GHOSTHUB_TMUX_SPLIT_IDENTITY_MISMATCH_"
    guard let start = command.range(of: prefix)?.lowerBound else { return nil }
    return String(command[start...].prefix { character in
        character.isLetter || character.isNumber
            || character == "_" || character == "-"
    })
}

@Suite("Native tmux connection identity", .serialized)
@MainActor
struct NativeTmuxSessionCoordinatorTests {
    @Test("dead remote tmux resolution invalidates before lease release")
    func deadResolutionInvalidatesConnection() async {
        let events = LockedValue<[String]>([])
        let host = SSHHostInfo(
            user: "dev",
            hostname: "build.example.test",
            port: nil
        )
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: RecordingNativeSessionSurfaceStore(),
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in
                .failure(.sshConnectionFailed(
                    host: host.hostname,
                    classification: SSHConnectionFailure.classify(
                        status: 255,
                        output: "Control socket connect(/tmp/dead): missing"
                    )
                ))
            },
            remoteConnectionProvider: { _, _ in
                testKwtSSHAttachment(
                    release: { events.withLock { $0.append("release") } },
                    invalidate: { events.withLock { $0.append("invalidate") } }
                )
            }
        )
        var disconnected = false
        coordinator.onStateChanged = { _, state in
            if case .disconnected = state {
                disconnected = true
            }
        }

        _ = coordinator.attach(
            hostID: UUID(),
            name: "review",
            host: .ssh(host),
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor {
            disconnected && events.load().count == 2
        }
        #expect(events.load() == ["invalidate", "release"])
    }

    @Test("a fail-closed pane split invalidates the pooled connection")
    func failClosedPaneSplitInvalidatesConnection() async throws {
        let invalidations = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let host = CommandHost.ssh(SSHHostInfo(
            user: "dev",
            hostname: "build.example.test",
            port: nil
        ))
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/local/bin/tmux")
            },
            remoteConnectionProvider: { _, _ in
                testKwtSSHAttachment(
                    invalidate: { invalidations.withLock { $0 += 1 } }
                )
            },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (0, coordinatorSplitClientOutput)
                }
                return (
                    255,
                    "Control socket connect(/tmp/dead): Connection refused\n"
                )
            },
            terminalOperationErrorDuration: .seconds(5)
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "dead-socket",
            host: host,
            sessionIdentity: coordinatorSplitIdentity
        )
        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { readyCount == 2 }
        let handler = try #require(store.surface.paneSplitShortcutHandler)

        handler(.down)

        await waitUntilMainActor { invalidations.load() > 0 }
        #expect(store.surface.terminalOperationErrorMessage != nil)
    }

    @Test("attachment reuses the version from binary resolution")
    func attachmentReusesResolvedVersion() async {
        let runnerCalls = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: {
                .success(ResolvedTmuxBinary(
                    path: "/opt/homebrew/bin/tmux",
                    version: "tmux 3.4a"
                ))
            },
            paneSplitter: TmuxPaneSplitter { _, _, _ in
                runnerCalls.withLock { $0 += 1 }
                return (1, "unexpected command")
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "one-version-probe",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        #expect(coordinator.supportsPaneSplitting(handle))
        #expect(runnerCalls.load() == 0)
    }

    @Test("creation carries a launch command but attachment drops it")
    func launchCommandIsCreationOnly() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") }
        )
        var readyHandles = Set<UUID>()
        coordinator.onSurfaceReady = { readyHandles.insert($0.id) }
        let hostID = UUID()
        let created = coordinator.attach(
            hostID: hostID,
            name: "created",
            host: .local,
            launchMode: .create,
            initialCommand: "exec codex"
        )
        let attached = coordinator.attach(
            hostID: hostID,
            name: "attached",
            host: .local,
            launchMode: .attach,
            initialCommand: "never-run-this"
        )

        await waitUntilMainActor {
            readyHandles == Set([created.id, attached.id])
        }
        _ = coordinator.surface(handle: created)
        let createCommand = try #require(
            store.requestedConfigurations.last?.command
        )
        _ = coordinator.surface(handle: attached)
        let attachCommand = try #require(
            store.requestedConfigurations.last?.command
        )

        #expect(createCommand.contains("exec codex"))
        #expect(!attachCommand.contains("never-run-this"))
        #expect(attachCommand.contains("attach-session"))
    }

    @Test("undiscovered attachments bind during surface establishment")
    func undiscoveredAttachmentBindsDuringSurfaceEstablishment() async throws {
        let identityCommands = LockedValue<[String]>([])
        let splitCommands = LockedValue(0)
        let releaseBinding = DispatchSemaphore(value: 0)
        defer { releaseBinding.signal() }
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    var isInitialBinding = false
                    identityCommands.withLock {
                        $0.append(command)
                        isInitialBinding = $0.count == 1
                    }
                    if isInitialBinding {
                        _ = releaseBinding.wait(timeout: .now() + 5)
                    }
                    return (0, coordinatorSplitClientOutput)
                }
                splitCommands.withLock { $0 += 1 }
                return (0, "")
            }
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "undiscovered",
            host: .local
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { identityCommands.load().count == 1 }
        #expect(!store.surface.terminalFindController.isAvailable)

        let bindingCommand = try #require(identityCommands.load().first)
        #expect(bindingCommand.contains("'list-clients' '-F'"))
        #expect(coordinator.supportsPaneSplitting(handle))
        let handler = try #require(store.surface.paneSplitShortcutHandler)
        handler(.right)
        #expect(splitCommands.load() == 0)
        #expect(store.surface.terminalOperationErrorMessage?.contains(
            "client identity is unavailable"
        ) == true)

        releaseBinding.signal()
        await waitUntilMainActor { readyCount == 2 }
        #expect(store.surface.terminalFindController.isAvailable)
        #expect(
            coordinator.attachedSessionIdentity(handle)
                == coordinatorSplitIdentity
        )
        handler(.right)
        await waitUntilMainActor { splitCommands.load() == 1 }
    }

    @Test("tmux older than 3.4 does not install pane split shortcuts")
    func oldTmuxDoesNotInstallSplitHandler() async {
        let store = RecordingNativeSessionSurfaceStore()
        let host = CommandHost.ssh(SSHHostInfo(
            user: "operator",
            hostname: "legacy.example.test",
            port: 2222
        ))
        let sshArguments = [
            "-F", "/dev/null",
            "-o", "HostName=legacy.internal.test",
        ]
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution(
                    "/usr/local/bin/tmux",
                    version: "tmux 3.3a"
                )
            },
            remoteConnectionProvider: { _, _ in
                testKwtSSHAttachment(arguments: sshArguments)
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "older-tmux",
            host: host,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)
        coordinator.requestAttachedSessionIdentity(handle)

        #expect(store.surface.paneSplitShortcutHandler == nil)
        #expect(!store.surface.terminalFindController.isAvailable)
        #expect(!coordinator.supportsPaneSplitting(handle))
        #expect(
            coordinator.attachedSessionIdentityResolution(handle)
                == .unavailable
        )
    }

    @Test("initial client binding retries while the attachment is live")
    func initialClientBindingRetries() async {
        let clientLookups = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                guard command.contains(
                    "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                ) else { return (0, "") }
                var attempt = 0
                clientLookups.withLock {
                    $0 += 1
                    attempt = $0
                }
                return attempt == 1
                    ? (1, "client token is not ready")
                    : (0, coordinatorSplitClientOutput)
            },
            clientIdentityRetryDelays: [.zero]
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "appearing",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor {
            clientLookups.load() == 2
                && store.surface.terminalFindController.isAvailable
        }

        #expect(clientLookups.load() == 2)
        #expect(store.surface.terminalFindController.isAvailable)
    }

    @Test("new named sessions use tmux create-or-attach mode")
    func namedSessionUsesCreateMode() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") }
        )
        var states: [ConnectionState] = []
        var readyHandles: [BorrowedTmuxSessionHandle] = []
        coordinator.onStateChanged = { _, state in states.append(state) }
        coordinator.onSurfaceReady = { readyHandles.append($0) }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "release-work",
            host: .local,
            launchMode: .create,
            sessionIdentity: coordinatorSplitIdentity
        )

        #expect(coordinator.surface(handle: handle) == nil)
        #expect(store.requestedConfigurations.isEmpty)
        await waitUntilMainActor { readyHandles == [handle] }
        #expect(!states.contains(.connected))

        _ = coordinator.surface(handle: handle)
        #expect(!store.requestedConfigurations.isEmpty)
        #expect(!states.contains(.connected))

        await waitUntilMainActor { states.contains(.connected) }
        #expect(states.filter { $0 == .connected }.count == 1)
        _ = coordinator.surface(handle: handle)
        #expect(states.filter { $0 == .connected }.count == 1)

        let command = try #require(store.requestedConfigurations.last?.command)
        #expect(command.contains("new-session"))
        #expect(command.contains("'-A'"))
        #expect(command.contains("'-E'"))
        #expect(command.contains("release-work"))
        #expect(!command.contains("'-d'"))
        #expect(!command.contains("attach-session"))
        #expect(!command.contains("status-style"))
    }

    @Test("surface reports connected once per attachment generation")
    func surfaceReportsConnectedOncePerAttachmentGeneration() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        let hostID = UUID()
        var states: [ConnectionState] = []
        var readyCount = 0
        coordinator.onStateChanged = { _, state in states.append(state) }
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: hostID,
            name: "release-work",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor {
            states.filter { $0 == .connected }.count == 1
        }

        _ = coordinator.surface(handle: handle)
        try await Task.sleep(for: .milliseconds(20))
        #expect(states.filter { $0 == .connected }.count == 1)
        #expect(coordinator.hasLaunched(handle))

        let close = try #require(store.surface.closeObservers[handle.id])
        close(false, 255)
        let reattached = coordinator.attach(
            hostID: hostID,
            name: "release-work",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )
        #expect(reattached == handle)
        await waitUntilMainActor { readyCount == 2 }
        _ = coordinator.surface(handle: reattached)
        await waitUntilMainActor {
            states.filter { $0 == .connected }.count == 2
        }

        #expect(coordinator.hasLaunched(handle))
    }

    @Test("new session launch reads the current terminal presentation style")
    func newSessionLaunchReadsCurrentPresentationStyle() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        var style = TmuxPresentationStyle(
            foreground: "#3B4851",
            background: "#FFFFFF"
        )
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            presentationStyleProvider: { style }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "docbank",
            host: .local,
            launchMode: .create,
            sessionIdentity: coordinatorSplitIdentity
        )
        style = TmuxPresentationStyle(
            foreground: "#EEEEEE",
            background: "#111111"
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains("fg=#EEEEEE,bg=#111111"))
        #expect(command.contains("status-style"))
        #expect(!command.contains("fg=#3B4851,bg=#FFFFFF"))
    }

    @Test("existing sessions keep their current presentation by default")
    func existingSessionKeepsCurrentPresentation() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            presentationStyleProvider: {
                TmuxPresentationStyle(
                    foreground: "#3B4851",
                    background: "#FFFFFF"
                )
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "existing",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(!command.contains("window-style"))
        #expect(!command.contains("status-style"))
    }

    @Test("existing sessions accept the shared presentation opt-in")
    func existingSessionAcceptsPresentationOptIn() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        var appliesPresentationStyle = true
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/opt/homebrew/bin/tmux") },
            presentationStyleProvider: {
                TmuxPresentationStyle(
                    foreground: "#3B4851",
                    background: "#FFFFFF"
                )
            },
            appliesPresentationStyleToExistingSessionsProvider: {
                appliesPresentationStyle
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "existing",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains("fg=#3B4851,bg=#FFFFFF"))
        #expect(command.contains("status-style"))
        #expect(coordinator.shouldApplyPresentationStyle(handle))

        appliesPresentationStyle = false
        #expect(!coordinator.shouldApplyPresentationStyle(handle))
    }

    @Test("protected attachment uses the reviewed workspace path")
    func protectedAttachmentUsesReviewedWorkspacePath() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            localKwtPathProvider: {
                "/Applications/Ghosthub.app/Contents/Helpers/kwt"
            },
            presentationStyleProvider: {
                TmuxPresentationStyle(
                    foreground: "#3B4851",
                    background: "#FFFFFF"
                )
            },
            appliesPresentationStyleToExistingSessionsProvider: { true }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "pr-32",
            host: .local,
            socketName: "kwt-pr-0123456789abcdef",
            tmuxAttachMode: .protected,
            workingDirectory: "/worktrees/pr-32",
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains(
            "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        ))
        #expect(command.contains("/worktrees/pr-32"))
        #expect(command.contains("kwt-pr-0123456789abcdef"))
        #expect(!command.contains("'open'"))
    }

    @Test("direct named socket uses ordinary kwt attachment")
    func directNamedSocketUsesKwtAttachment() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            localKwtPathProvider: {
                "/Applications/Ghosthub.app/Contents/Helpers/kwt"
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "kwt-widget-feature",
            host: .local,
            socketName: "kwt",
            tmuxAttachMode: .direct,
            workingDirectory: "/worktrees/widget",
            openWorkspace: true,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains("Helpers/kwt"))
        #expect(command.contains("'open'"))
        #expect(command.contains("/worktrees/widget"))
        #expect(!command.contains("'pr' 'attach'"))
    }

    @Test("ordinary worktree attachment enables mouse after kwt connects")
    func ordinaryWorktreeUsesKwtAttachment() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            localKwtPathProvider: {
                "/Applications/Ghosthub.app/Contents/Helpers/kwt"
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "kwt-widget-feature",
            host: .local,
            workingDirectory: "/worktrees/widget",
            openWorkspace: true,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains("Helpers/kwt"))
        #expect(command.contains("open"))
        #expect(command.contains("/worktrees/widget"))
        #expect(command.contains("ghosthub_kwt_pid"))
        #expect(command.contains("'set-option'"))
        #expect(command.contains("'=kwt-widget-feature:'"))
        #expect(command.contains("mouse"))
        #expect(!command.contains("@ghosthub_kwt_presentation_ready"))
        #expect(!command.contains("--start-session"))
        #expect(!command.contains("attach-session"))
    }

    @Test("remote attachment uses non-enrolling host-key policy")
    func remoteAttachmentUsesNonEnrollingHostKeyPolicy() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let releases = LockedValue(0)
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            remoteConnectionProvider: { _, _ in
                testKwtSSHAttachment(arguments: [
                    "-o", "StrictHostKeyChecking=yes",
                ]) {
                    releases.withLock { $0 += 1 }
                }
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "existing",
            host: .ssh(SSHHostInfo(
                user: "operator",
                hostname: "build.example.test",
                port: nil
            )),
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains("StrictHostKeyChecking=yes"))

        let close = try #require(store.surface.closeObservers[handle.id])
        close(false, 0)
        await waitUntilMainActor { releases.load() == 1 }
        coordinator.detach(
            hostID: handle.hostID,
            name: handle.name,
            socketName: handle.socketName
        )
        #expect(releases.load() == 1)
    }

    @Test("split shortcuts use the attachment's fixed remote route")
    func splitShortcutUsesAttachmentRoute() async throws {
        let calls = LockedValue<[(CommandHost, [String], String)]>([])
        let resolutionArguments = LockedValue<[String]?>(nil)
        let routeProviderCalls = LockedValue(0)
        let routeArguments = LockedValue([
            "-F", "/dev/null",
            "-o", "HostName=attached.example.test",
            "-o", "ControlPath=/tmp/ghosthub-attached",
        ])
        let store = RecordingNativeSessionSurfaceStore()
        let host = CommandHost.ssh(SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: 2222
        ))
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, arguments in
                resolutionArguments.store(arguments)
                return successfulTmuxResolution("/usr/local/bin/tmux")
            },
            remoteConnectionProvider: { _, _ in
                routeProviderCalls.withLock { $0 += 1 }
                return testKwtSSHAttachment(
                    arguments: routeArguments.load()
                )
            },
            paneSplitter: supportedPaneSplitter { host, arguments, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (0, coordinatorSplitClientOutput)
                }
                calls.withLock { $0.append((host, arguments, command)) }
                return (1, "no space for new pane\n")
            },
            terminalOperationErrorDuration: .milliseconds(100)
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "release-work",
            host: host,
            socketName: "isolated",
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        routeArguments.store([
            "-F", "/dev/null",
            "-o", "HostName=reconfigured.example.test",
            "-o", "ControlPath=/tmp/ghosthub-reconfigured",
        ])
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { readyCount == 2 }
        let handler = try #require(store.surface.paneSplitShortcutHandler)
        handler(.down)
        await waitUntilMainActor { calls.load().count == 1 }
        await waitUntilMainActor {
            store.surface.terminalOperationErrorMessage != nil
        }

        let call = try #require(calls.load().first)
        #expect(call.0 == host)
        #expect(resolutionArguments.load() == call.1)
        #expect(call.1 == [
            "-F", "/dev/null",
            "-o", "HostName=attached.example.test",
            "-o", "ControlPath=/tmp/ghosthub-attached",
        ])
        #expect(routeProviderCalls.load() == 1)
        #expect(!call.2.contains("'list-clients' '-F'"))
        #expect(call.2.contains("'refresh-client' '-t' '/dev/ttys001'"))
        #expect(call.2.contains("split-window"))
        #expect(call.2.contains("-v"))
        #expect(!call.2.contains("=release-work:"))
        #expect(store.surface.terminalOperationErrorMessage?.contains(
            "release-work"
        ) == true)
        #expect(store.surface.terminalOperationErrorMessage?.contains(
            "no space for new pane"
        ) == true)
        await waitUntilMainActor {
            store.surface.terminalOperationErrorMessage == nil
        }
    }

    @Test("remote tmux path cache follows the frozen SSH route")
    func remoteTmuxPathCacheUsesConnectionIdentity() async {
        let routeArguments = LockedValue([
            "-F", "/dev/null",
            "-o", "HostName=first.example.test",
        ])
        let resolvedArguments = LockedValue<[[String]]>([])
        let store = RecordingNativeSessionSurfaceStore()
        let hostID = UUID()
        let host = CommandHost.ssh(SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: nil
        ))
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, arguments in
                resolvedArguments.withLock { $0.append(arguments) }
                return successfulTmuxResolution("/usr/local/bin/tmux")
            },
            remoteConnectionProvider: { _, _ in
                testKwtSSHAttachment(
                    arguments: routeArguments.load()
                )
            }
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }

        _ = coordinator.attach(
            hostID: hostID,
            name: "first",
            host: host
        )
        await waitUntilMainActor { readyCount == 1 }
        routeArguments.store([
            "-F", "/dev/null",
            "-o", "HostName=second.example.test",
        ])
        _ = coordinator.attach(
            hostID: hostID,
            name: "second",
            host: host
        )
        await waitUntilMainActor { readyCount == 2 }
        _ = coordinator.attach(
            hostID: hostID,
            name: "third",
            host: host
        )
        await waitUntilMainActor { readyCount == 3 }

        #expect(resolvedArguments.load() == [
            ["-F", "/dev/null", "-o", "HostName=first.example.test"],
        ])
    }

    @Test("keyboard splits require effective terminal focus")
    func keyboardSplitRequiresTerminalFocus() async throws {
        let calls = LockedValue<[String]>([])
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (0, coordinatorSplitClientOutput)
                }
                calls.withLock { $0.append(command) }
                return (0, "")
            }
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "focused",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { readyCount == 2 }
        coordinator.requestPaneSplit(
            .right,
            handle: handle,
            requiresKeyboardFocus: true
        )
        try await Task.sleep(for: .milliseconds(20))
        #expect(calls.load().isEmpty)

        coordinator.requestPaneSplit(
            .right,
            handle: handle,
            requiresKeyboardFocus: false
        )
        await waitUntilMainActor { calls.load().count == 1 }

        store.surface.hasEffectiveKeyboardFocus = true
        coordinator.requestPaneSplit(
            .down,
            handle: handle,
            requiresKeyboardFocus: true
        )
        await waitUntilMainActor { calls.load().count == 2 }
    }

    @Test("native Windows surfaces do not intercept pane split shortcuts")
    func windowsSurfaceDoesNotInstallSplitHandler() async {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("tmux.exe") },
            remoteConnectionProvider: { _, _ in
                testKwtSSHAttachment()
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "windows",
            host: .ssh(SSHHostInfo(
                user: "operator",
                hostname: "windows.example.test",
                port: nil,
                platform: .windows
            )),
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)

        #expect(store.surface.paneSplitShortcutHandler == nil)
    }

    @Test("split requests run in attachment order")
    func splitRequestsAreSerialized() async throws {
        let events = LockedValue<[String]>([])
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (0, coordinatorSplitClientOutput)
                }
                if !command.contains("-v") {
                    events.withLock { $0.append("start-right") }
                    _ = releaseFirst.wait(timeout: .now() + 5)
                    events.withLock { $0.append("finish-right") }
                } else {
                    events.withLock { $0.append("start-down") }
                    events.withLock { $0.append("finish-down") }
                }
                return (0, "")
            }
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "ordered",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { readyCount == 2 }
        let handler = try #require(store.surface.paneSplitShortcutHandler)
        handler(.right)
        await waitUntilMainActor { events.load() == ["start-right"] }
        handler(.down)
        try await Task.sleep(for: .milliseconds(20))
        #expect(events.load() == ["start-right"])

        releaseFirst.signal()
        await waitUntilMainActor { events.load().count == 4 }
        #expect(events.load() == [
            "start-right",
            "finish-right",
            "start-down",
            "finish-down",
        ])
    }

    @Test("detaching cancels the running split and its queue")
    func detachCancelsSplitQueue() async throws {
        let events = LockedValue<[String]>([])
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (0, coordinatorSplitClientOutput)
                }
                if command.contains("'set-hook' '-gu'"),
                   !command.contains("'refresh-client'") {
                    return (0, "")
                }
                if !command.contains("-v") {
                    events.withLock { $0.append("start-right") }
                    let deadline = Date().addingTimeInterval(5)
                    while Date() < deadline,
                          !withUnsafeCurrentTask(body: {
                              $0?.isCancelled == true
                          }) {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    let wasCancelled = withUnsafeCurrentTask(body: {
                        $0?.isCancelled == true
                    })
                    events.withLock {
                        $0.append(wasCancelled ? "cancel-right" : "timeout")
                    }
                } else {
                    events.withLock { $0.append("run-down") }
                }
                return (0, "")
            }
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let hostID = UUID()
        let handle = coordinator.attach(
            hostID: hostID,
            name: "cancelled",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { readyCount == 2 }
        let handler = try #require(store.surface.paneSplitShortcutHandler)
        handler(.right)
        await waitUntilMainActor { events.load() == ["start-right"] }
        handler(.down)

        coordinator.detach(hostID: hostID, name: "cancelled")

        await waitUntilMainActor { events.load().count == 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(events.load() == ["start-right", "cancel-right"])
    }

    @Test("preview identity retries a failed client binding")
    func failedClientBindingRetriesForPreviewIdentity() async throws {
        let clientLookups = LockedValue(0)
        let splitCommands = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    var attempt = 0
                    clientLookups.withLock {
                        $0 += 1
                        attempt = $0
                    }
                    if attempt <= 2 {
                        return (1, "no clients yet")
                    }
                    return (0, coordinatorSplitClientOutput)
                }
                splitCommands.withLock { $0 += 1 }
                return (0, "")
            },
            clientIdentityRetryDelays: [.zero]
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "appearing",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { clientLookups.load() == 2 }
        try await Task.sleep(for: .milliseconds(20))
        coordinator.requestAttachedSessionIdentity(handle)
        await waitUntilMainActor {
            coordinator.attachedSessionIdentity(handle)
                == coordinatorSplitIdentity
        }
        #expect(coordinator.supportsPaneSplitting(handle))
        let handler = try #require(store.surface.paneSplitShortcutHandler)
        handler(.right)
        #expect(store.surface.terminalOperationErrorMessage == nil)
        await waitUntilMainActor { splitCommands.load() == 1 }
        #expect(clientLookups.load() == 4)
        #expect(store.surface.terminalOperationErrorMessage == nil)
    }

    @Test("capture revalidation observes a client session switch")
    func captureRevalidationObservesSessionSwitch() async {
        let switchedOutput =
            "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY\t123\t789\t321"
                + "\t/dev/ttys001\t$8\t654\t%10\n"
        let clientLookups = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                guard command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY")
                else { return (0, "") }
                clientLookups.withLock { $0 += 1 }
                let lookup = clientLookups.load()
                return (
                    0,
                    lookup == 1
                        ? coordinatorSplitClientOutput
                        : switchedOutput
                )
            }
        )
        var isReady = false
        coordinator.onSurfaceReady = { _ in isReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "switching",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isReady }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor {
            coordinator.attachedSessionIdentity(handle)
                == coordinatorSplitIdentity
        }

        let current = await coordinator.revalidateAttachedSessionIdentity(
            handle
        )

        #expect(current == TmuxSessionIdentity(
            serverPID: "123",
            sessionID: "$8",
            createdAt: "654"
        ))
        #expect(
            coordinator.attachedSessionIdentity(handle)
                == coordinatorSplitIdentity
        )
    }

    @Test("a replacement client reusing the attachment TTY is rejected")
    func reusedClientTTYIsRejected() async throws {
        let clientLookups = LockedValue(0)
        let splitCommands = LockedValue(0)
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    var lookup = 0
                    clientLookups.withLock {
                        $0 += 1
                        lookup = $0
                    }
                    if lookup <= 2 {
                        return (0, coordinatorSplitClientOutput)
                    }
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY\t123\t790\t322"
                            + "\t/dev/ttys001\t$7\t456\t%9\n"
                    )
                }
                splitCommands.withLock { $0 += 1 }
                return (0, "")
            }
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "reused-tty",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { readyCount == 2 }
        let handler = try #require(store.surface.paneSplitShortcutHandler)
        handler(.right)
        await waitUntilMainActor { splitCommands.load() == 1 }
        handler(.down)
        await waitUntilMainActor {
            store.surface.terminalOperationErrorMessage != nil
                || splitCommands.load() == 2
        }

        #expect(clientLookups.load() == 3)
        #expect(splitCommands.load() == 1)
        #expect(store.surface.terminalOperationErrorMessage?.contains(
            "attached tmux session changed"
        ) == true)
    }

    @Test("the attached client may move to another pane between splits")
    func attachedClientPaneMayChange() async throws {
        let clientLookups = LockedValue(0)
        let splitCommands = LockedValue<[String]>([])
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    var lookup = 0
                    clientLookups.withLock {
                        $0 += 1
                        lookup = $0
                    }
                    if lookup <= 2 {
                        return (0, coordinatorSplitClientOutput)
                    }
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY\t123\t789\t321"
                            + "\t/dev/ttys001\t$7\t456\t%10\n"
                    )
                }
                splitCommands.withLock { $0.append(command) }
                return (0, "")
            }
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "moving-client",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { readyCount == 2 }
        let handler = try #require(store.surface.paneSplitShortcutHandler)
        handler(.right)
        await waitUntilMainActor { splitCommands.load().count == 1 }
        handler(.down)
        await waitUntilMainActor {
            store.surface.terminalOperationErrorMessage != nil
                || splitCommands.load().count == 2
        }

        #expect(clientLookups.load() == 3)
        #expect(splitCommands.load().count == 2)
        #expect(splitCommands.load().last?.contains("'%10'") == true)
        #expect(store.surface.terminalOperationErrorMessage == nil)
    }

    @Test("an atomic pane movement rereads the client and retries once")
    func atomicPaneMovementRetriesOnce() async throws {
        let clientLookups = LockedValue(0)
        let splitCommands = LockedValue<[String]>([])
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    var lookup = 0
                    clientLookups.withLock {
                        $0 += 1
                        lookup = $0
                    }
                    if lookup <= 2 {
                        return (0, coordinatorSplitClientOutput)
                    }
                    return (
                        0,
                        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY\t123\t789\t321"
                            + "\t/dev/ttys001\t$7\t456\t%10\n"
                    )
                }
                var attempt = 0
                splitCommands.withLock {
                    $0.append(command)
                    attempt = $0.count
                }
                if attempt == 1,
                   let marker = splitMismatchMarker(in: command) {
                    return (0, marker + "\n")
                }
                return (0, "")
            }
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "moving-during-split",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { readyCount == 2 }
        let handler = try #require(store.surface.paneSplitShortcutHandler)
        handler(.right)
        await waitUntilMainActor { splitCommands.load().count == 2 }

        #expect(clientLookups.load() == 3)
        #expect(splitCommands.load().last?.contains("'%10'") == true)
        #expect(store.surface.terminalOperationErrorMessage == nil)
    }

    @Test("endpoint changes replace provisioning and active handles")
    func endpointChangesReplaceHandles() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            remoteConnectionProvider: { _, _ in
                testKwtSSHAttachment()
            }
        )
        var states: [UUID: ConnectionState] = [:]
        coordinator.onStateChanged = { handle, state in
            states[handle.id] = state
        }
        let hostID = UUID()
        let first = coordinator.attach(
            hostID: hostID,
            name: "shared",
            host: .ssh(.init(
                user: "user",
                hostname: "old.example.com",
                port: nil
            )),
            sessionIdentity: coordinatorSplitIdentity
        )
        let second = coordinator.attach(
            hostID: hostID,
            name: "shared",
            host: .ssh(.init(
                user: "user",
                hostname: "new.example.com",
                port: nil
            )),
            sessionIdentity: coordinatorSplitIdentity
        )

        #expect(first.id != second.id)
        await waitUntilMainActor {
            _ = coordinator.surface(handle: second)
            return states[second.id] == .connected
        }
        let secondSurfaceKey = try #require(store.requestedKeys.last)

        let third = coordinator.attach(
            hostID: hostID,
            name: "shared",
            host: .ssh(.init(
                user: "user",
                hostname: "third.example.com",
                port: 2222
            )),
            sessionIdentity: coordinatorSplitIdentity
        )

        #expect(third.id != second.id)
        #expect(store.removedKeys.last == secondSurfaceKey)
        let requestCount = store.requestedKeys.count
        _ = coordinator.surface(handle: second)
        #expect(store.requestedKeys.count == requestCount)
    }

    @Test("rejected terminal surfaces never report command launch")
    func rejectedSurfaceDoesNotLaunch() async {
        let store = RecordingNativeSessionSurfaceStore(
            launchError: SurfaceLaunchTestError.rejected
        )
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        var states: [ConnectionState] = []
        var isSurfaceReady = false
        coordinator.onStateChanged = { _, state in states.append(state) }
        coordinator.onSurfaceReady = { _ in isSurfaceReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "release-work",
            host: .local,
            launchMode: .create,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)
        #expect(!states.contains {
            if case .disconnected = $0 {
                return true
            }
            return false
        })
        await waitUntilMainActor {
            states.contains {
                if case .disconnected = $0 {
                    return true
                }
                return false
            }
        }

        #expect(!states.contains(.connected))
        #expect(!coordinator.hasLaunched(handle))
        #expect(coordinator.attachmentClosure(handle) == .launchFailed)
        #expect(store.removedKeys.count == 1)
    }

    @Test("a missing terminal surface is a launch failure")
    func missingSurfaceDoesNotLaunch() async {
        let store = MissingTmuxSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        var states: [ConnectionState] = []
        var isSurfaceReady = false
        coordinator.onStateChanged = { _, state in states.append(state) }
        coordinator.onSurfaceReady = { _ in isSurfaceReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "release-work",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor {
            states.contains {
                if case .disconnected = $0 {
                    return true
                }
                return false
            }
        }

        #expect(!states.contains(.connected))
        #expect(!coordinator.hasLaunched(handle))
        #expect(coordinator.attachmentClosure(handle) == .launchFailed)
        #expect(store.removedKeyCount == 1)
    }

    @Test("a detached live client records a closed attachment")
    func detachedLiveClientClosesAttachment() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        var states: [ConnectionState] = []
        var isSurfaceReady = false
        coordinator.onStateChanged = { _, state in states.append(state) }
        coordinator.onSurfaceReady = { _ in isSurfaceReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "release-work",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )
        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { states.contains(.connected) }

        let close = try #require(store.surface.closeObservers[handle.id])
        close(true, nil)

        #expect(coordinator.hasClosedAttachment(handle))
        #expect(coordinator.attachmentClosure(handle) == .detached)
        #expect(states.last == .disconnected(
            reason: "The tmux attachment to “release-work” closed."
        ))
    }

    @Test("a successful tmux client exit records a manual detach")
    func successfulClientExitRecordsDetach() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") }
        )
        var isSurfaceReady = false
        coordinator.onSurfaceReady = { _ in isSurfaceReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "release-work",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )
        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)

        let close = try #require(store.surface.closeObservers[handle.id])
        close(false, 0)

        #expect(coordinator.hasClosedAttachment(handle))
        #expect(coordinator.attachmentClosure(handle) == .detached)
    }

    @Test("recorded SSH transport status overrides libghostty exit status")
    func recordsTransportExitCode() async throws {
        let statusDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: statusDirectory) }
        let store = RecordingNativeSessionSurfaceStore()
        let invalidations = LockedValue(0)
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            remoteConnectionProvider: { _, _ in
                testKwtSSHAttachment(invalidate: {
                    invalidations.withLock { $0 += 1 }
                })
            },
            remoteExitStatusDirectory: statusDirectory
        )
        var isSurfaceReady = false
        coordinator.onSurfaceReady = { _ in isSurfaceReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "release-work",
            host: .ssh(SSHHostInfo(
                user: "dev",
                hostname: "build.example.test",
                port: nil
            )),
            sessionIdentity: coordinatorSplitIdentity
        )
        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)

        let statusFile = try #require(
            FileManager.default.contentsOfDirectory(
                at: statusDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        try "255\n".write(
            to: statusFile, atomically: true, encoding: .utf8
        )

        let close = try #require(store.surface.closeObservers[handle.id])
        close(false, 0)

        #expect(coordinator.hasClosedAttachment(handle))
        #expect(
            coordinator.attachmentClosure(handle)
                == .processExited(code: 255)
        )
        await waitUntilMainActor { invalidations.load() == 1 }
    }

    @Test("interactive sizing reports an attachment replacement")
    func interactiveSizingReportsAttachmentReplacement() async throws {
        let identityLookups = LockedValue(0)
        let promotionStarted = LockedValue(false)
        let promotionMutations = LockedValue(0)
        let releasePromotion = DispatchSemaphore(value: 0)
        defer { releasePromotion.signal() }
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    identityLookups.withLock { $0 += 1 }
                    let lookup = identityLookups.load()
                    if lookup == 2 {
                        promotionStarted.withLock { $0 = true }
                        releasePromotion.wait()
                    }
                    return (0, coordinatorSplitClientOutput)
                }
                if command.contains("'!ignore-size'") {
                    promotionMutations.withLock { $0 += 1 }
                }
                return (0, "")
            }
        )
        var readyCount = 0
        coordinator.onSurfaceReady = {
            (_: BorrowedTmuxSessionHandle) in readyCount += 1
        }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "replaced-preview",
            host: CommandHost.local,
            sessionIdentity: coordinatorSplitIdentity,
            ignoresClientSize: true,
            previewGridSize: TmuxGridSize(columns: 120, rows: 37)
        )
        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { identityLookups.load() == 1 }

        let firstPromotion = Task { @MainActor in
            await coordinator.enableInteractiveSizing(for: handle)
        }
        await waitUntilMainActor { promotionStarted.load() }
        let close = try #require(store.surface.closeObservers[handle.id])
        close(true, nil as UInt32?)
        let readyCountBeforeReplacement = readyCount
        let replacement = coordinator.attach(
            hostID: handle.hostID,
            name: handle.name,
            host: CommandHost.local,
            sessionIdentity: coordinatorSplitIdentity,
            ignoresClientSize: true,
            previewGridSize: TmuxGridSize(columns: 120, rows: 37)
        )
        await waitUntilMainActor {
            readyCount > readyCountBeforeReplacement
        }
        _ = coordinator.surface(handle: replacement)
        releasePromotion.signal()

        let firstResult = await firstPromotion.value
        #expect(firstResult == TmuxClientSizingTransitionResult.stale)
        let replacementResult = await coordinator.enableInteractiveSizing(
            for: replacement
        )
        #expect(replacementResult == TmuxClientSizingTransitionResult.applied)
        #expect(promotionMutations.load() == 1)
    }

    @Test("interactive sizing refreshes geometry before clearing ignore-size")
    func interactiveSizingRefreshesGeometryBeforePromotion() async {
        let store = RecordingNativeSessionSurfaceStore()
        let promotionEvents = LockedValue<[String]>([])
        store.surface.onClearPreviewGrid = {
            promotionEvents.withLock { $0.append("geometry") }
        }
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (0, coordinatorSplitClientOutput)
                }
                if command.contains("'!ignore-size'") {
                    promotionEvents.withLock { $0.append("sizing") }
                }
                return (0, "")
            }
        )
        var isSurfaceReady = false
        coordinator.onSurfaceReady = { _ in isSurfaceReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "promotion-order",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity,
            ignoresClientSize: true,
            previewGridSize: TmuxGridSize(columns: 120, rows: 37)
        )
        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)

        let result = await coordinator.enableInteractiveSizing(for: handle)

        #expect(result == TmuxClientSizingTransitionResult.applied)
        #expect(promotionEvents.load() == ["geometry", "sizing", "geometry"])
        #expect(store.surface.clearPreviewGridCount == 2)
    }

    @Test("stale promotion restore recovers the tmux window dimensions")
    func stalePromotionRestoreRecoversTmuxWindowDimensions() async throws {
        guard case let .success(binary) = TmuxBinaryResolver()
            .resolveTmuxBinary(),
            TmuxPaneSplitter.supportsPaneSplitting(
                version: binary.version,
                host: .local
            )
        else { return }
        let server = try TestTmuxServer(
            tmuxPath: binary.path,
            socket: .runOwned(purpose: "stale-promotion-size")
        )
        defer { server.stop() }
        try server.createSession("restored")
        let status = AccountCommandRunner.runProcess(
            executable: binary.path,
            arguments: server.connectionArguments + [
                "set-option", "-g", "status", "off",
            ],
            timeout: 5
        )
        #expect(status.status == 0)

        let clientToken = UUID().uuidString.lowercased()
        let clientTTYDirectory = try #require(
            ProcessInfo.processInfo.environment["TMUX_TMPDIR"]
        )
        let client = try TestTmuxClient(
            tmuxPath: binary.path,
            socketName: server.socketName,
            sessionName: "restored",
            clientToken: clientToken,
            clientTTYDirectory: URL(
                fileURLWithPath: clientTTYDirectory,
                isDirectory: true
            )
        )
        defer { client.stop() }
        _ = try await client.publishedTTY()
        let target = TmuxPaneSplitTarget(
            host: .local,
            tmuxPath: binary.path,
            sessionName: "restored",
            socketName: server.socketName,
            sshConnectionArguments: [],
            clientToken: clientToken,
            clientTTYDirectory: clientTTYDirectory
        )
        let clientIdentity = try await TmuxPaneSplitter()
            .clientIdentity(target: target).get()
        let identityOutput = [
            "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY",
            clientIdentity.serverPID,
            clientIdentity.clientPID,
            clientIdentity.clientCreatedAt,
            clientIdentity.clientTTY,
            clientIdentity.sessionID,
            clientIdentity.sessionCreatedAt,
            clientIdentity.paneID,
        ].joined(separator: "\t") + "\n"
        let interactiveGrid = TmuxGridSize(columns: 80, rows: 24)
        let previewGrid = TmuxGridSize(columns: 120, rows: 37)
        let interactiveResize = AccountCommandRunner.runProcess(
            executable: binary.path,
            arguments: server.connectionArguments + [
                "resize-window", "-t", "restored:",
                "-x", String(interactiveGrid.columns),
                "-y", String(interactiveGrid.rows),
            ],
            timeout: 5
        )
        #expect(interactiveResize.status == 0)

        let store = RecordingNativeSessionSurfaceStore()
        var previewResizeStatus: Int32?
        store.surface.onPreviewGridSize = { gridSize in
            let clients = AccountCommandRunner.runProcess(
                executable: binary.path,
                arguments: server.connectionArguments + [
                    "list-clients", "-F",
                    "#{client_tty}\t#{client_flags}",
                ],
                timeout: 5
            )
            let clientFlags = clients.stdout.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first { $0.hasPrefix(clientIdentity.clientTTY + "\t") }
            guard clientFlags?.contains("ignore-size") == false else {
                return
            }
            previewResizeStatus = AccountCommandRunner.runProcess(
                executable: binary.path,
                arguments: server.connectionArguments + [
                    "resize-window", "-t", "restored:",
                    "-x", String(gridSize.columns),
                    "-y", String(gridSize.rows),
                ],
                timeout: 5
            ).status
        }
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { .success(binary) },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (0, identityOutput)
                }
                let result = AccountCommandRunner.runProcess(
                    executable: "/bin/sh",
                    arguments: ["-c", command],
                    timeout: 15
                )
                return (result.status, result.stdout + result.stderr)
            }
        )
        var isSurfaceReady = false
        coordinator.onSurfaceReady = { _ in isSurfaceReady = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "restored",
            host: CommandHost.local,
            socketName: server.socketName,
            sessionIdentity: clientIdentity.sessionIdentity
        )
        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)

        #expect(
            await coordinator.restorePreviewSizing(previewGrid, for: handle)
                == .applied
        )
        let measured = AccountCommandRunner.runProcess(
            executable: binary.path,
            arguments: server.connectionArguments + [
                "display-message", "-p", "-t", "restored:",
                "#{window_width}x#{window_height}",
            ],
            timeout: 5
        )

        #expect(previewResizeStatus == 0)
        #expect(measured.status == 0)
        #expect(
            measured.stdout.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            ) == "120x37"
        )
    }

    @Test("interactive sizing suppresses grid refresh during promotion")
    func interactiveSizingSuppressesGridRefreshDuringPromotion() async {
        let promotionStarted = LockedValue(false)
        let releasePromotion = DispatchSemaphore(value: 0)
        defer { releasePromotion.signal() }
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            paneSplitter: supportedPaneSplitter { _, _, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (0, coordinatorSplitClientOutput)
                }
                if command.contains("'!ignore-size'") {
                    promotionStarted.withLock { $0 = true }
                    releasePromotion.wait()
                }
                return (0, "")
            }
        )
        var isSurfaceReady = false
        coordinator.onSurfaceReady = { _ in isSurfaceReady = true }
        let initialGrid = TmuxGridSize(columns: 120, rows: 37)
        let refreshedGrid = TmuxGridSize(columns: 140, rows: 41)
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "promotion-refresh",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity,
            ignoresClientSize: true,
            previewGridSize: initialGrid
        )
        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)

        let promotion = Task { @MainActor in
            await coordinator.enableInteractiveSizing(for: handle)
        }
        await waitUntilMainActor { promotionStarted.load() }
        coordinator.updatePreviewGridSize(refreshedGrid, for: handle)
        releasePromotion.signal()

        let result = await promotion.value

        #expect(result == TmuxClientSizingTransitionResult.applied)
        #expect(store.surface.previewGridSizes == [
            initialGrid,
        ])
        #expect(store.surface.clearPreviewGridCount == 2)
    }

    @Test("unchanged preview grids do not resize live surfaces")
    func unchangedPreviewGridDoesNotResizeSurface() async {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: {
                successfulTmuxResolution("/opt/homebrew/bin/tmux")
            }
        )
        var isSurfaceReady = false
        coordinator.onSurfaceReady = { _ in isSurfaceReady = true }
        let initialGrid = TmuxGridSize(columns: 180, rows: 50)
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "stable-preview",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity,
            ignoresClientSize: true,
            previewGridSize: initialGrid
        )
        await waitUntilMainActor { isSurfaceReady }
        _ = coordinator.surface(handle: handle)
        _ = coordinator.surface(handle: handle)

        coordinator.updatePreviewGridSize(initialGrid, for: handle)
        coordinator.updatePreviewGridSize(
            TmuxGridSize(columns: 160, rows: 48),
            for: handle
        )

        #expect(store.surface.previewGridSizes == [
            initialGrid,
            TmuxGridSize(columns: 160, rows: 48),
        ])
    }

    @Test("a reconnected preview sizes its replacement surface")
    func reconnectedPreviewSizesReplacementSurface() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: {
                successfulTmuxResolution("/opt/homebrew/bin/tmux")
            }
        )
        var readyCount = 0
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        let grid = TmuxGridSize(columns: 180, rows: 50)
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "reconnected-preview",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity,
            ignoresClientSize: true,
            previewGridSize: grid
        )
        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)

        let close = try #require(store.surface.closeObservers[handle.id])
        close(true, nil)
        let replacement = coordinator.attach(
            hostID: handle.hostID,
            name: handle.name,
            host: .local,
            sessionIdentity: coordinatorSplitIdentity,
            ignoresClientSize: true,
            previewGridSize: grid
        )
        await waitUntilMainActor { readyCount == 2 }
        _ = coordinator.surface(handle: replacement)

        #expect(replacement == handle)
        #expect(store.surface.previewGridSizes == [grid, grid])
    }

    @Test("failed provisioning does not leak pending interactive sizing")
    func failedProvisioningDoesNotLeakInteractiveSizing() async throws {
        let resolutions = LockedValue(0)
        let releaseResolution = DispatchSemaphore(value: 0)
        defer { releaseResolution.signal() }
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: {
                var attempt = 0
                resolutions.withLock {
                    $0 += 1
                    attempt = $0
                }
                guard attempt == 1 else {
                    return successfulTmuxResolution("/usr/bin/tmux")
                }
                _ = releaseResolution.wait(timeout: .now() + 5)
                return .failure(.shellFailed(status: 1))
            }
        )
        var readyCount = 0
        var sawDisconnected = false
        coordinator.onSurfaceReady = { _ in readyCount += 1 }
        coordinator.onStateChanged = { _, state in
            if case .disconnected = state {
                sawDisconnected = true
            }
        }
        let grid = TmuxGridSize(columns: 120, rows: 37)
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "leaked-sizing",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity,
            ignoresClientSize: true,
            previewGridSize: grid
        )
        let promotion = await coordinator.enableInteractiveSizing(for: handle)
        #expect(promotion == TmuxClientSizingTransitionResult.pending)
        releaseResolution.signal()
        await waitUntilMainActor { sawDisconnected }

        let replacement = coordinator.attach(
            hostID: handle.hostID,
            name: handle.name,
            host: .local,
            sessionIdentity: coordinatorSplitIdentity,
            ignoresClientSize: true,
            previewGridSize: grid
        )
        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: replacement)

        let command = try #require(
            store.requestedConfigurations.last?.command
        )
        #expect(command.contains("ignore-size"))
    }
}

private enum SurfaceLaunchTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "Surface launch rejected" }
}

@MainActor
private final class MissingTmuxSurfaceStore: NativeSessionSurfaceStoring {
    private(set) var removedKeyCount = 0

    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> (any NativeSessionPaneSurfacing)? {
        nil
    }

    func removeSurface(for key: SurfaceKey) {
        removedKeyCount += 1
    }
}
