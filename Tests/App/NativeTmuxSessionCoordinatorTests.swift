import GhosthubTransport
import Foundation
import GhosthubTerminal
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

@Suite("Native tmux connection identity", .serialized)
@MainActor
struct NativeTmuxSessionCoordinatorTests {
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

        let bindingCommand = try #require(identityCommands.load().first)
        #expect(bindingCommand.contains("'list-clients' '-F'"))
        #expect(coordinator.supportsPaneSplitting(handle))
        let handler = try #require(store.surface.tmuxSplitShortcutHandler)
        handler(.right)
        #expect(splitCommands.load() == 0)
        #expect(store.surface.tmuxSplitErrorMessage?.contains(
            "client identity is unavailable"
        ) == true)

        releaseBinding.signal()
        await waitUntilMainActor { readyCount == 2 }
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
            sshConnectionArgumentsProvider: { _ in
                SSHConnectionArgumentsSnapshot(arguments: sshArguments)
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

        #expect(store.surface.tmuxSplitShortcutHandler == nil)
        #expect(!coordinator.supportsPaneSplitting(handle))
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

    @Test("isolated session socket participates in command routing")
    func isolatedSessionUsesReturnedSocket() async throws {
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

    @Test("ordinary worktree path attaches directly through kwt")
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
        #expect(!command.contains("ghosthub_kwt_pid"))
        #expect(!command.contains("@ghosthub_kwt_presentation_ready"))
        #expect(!command.contains("--start-session"))
        #expect(!command.contains("attach-session"))
    }

    @Test("remote attachment uses non-enrolling host-key policy")
    func remoteAttachmentUsesNonEnrollingHostKeyPolicy() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
            sshConnectionArgumentsProvider: { _ in
                SSHConnectionArgumentsSnapshot(arguments: [
                    "-o", "StrictHostKeyChecking=yes",
                ])
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
            sshConnectionArgumentsProvider: { _ in
                routeProviderCalls.withLock { $0 += 1 }
                return SSHConnectionArgumentsSnapshot(
                    arguments: routeArguments.load()
                )
            },
            paneSplitter: supportedPaneSplitter { host, arguments, command in
                if command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") {
                    return (0, coordinatorSplitClientOutput)
                }
                calls.withLock { $0.append((host, arguments, command)) }
                return (1, "no space for new pane\n")
            }
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
        let handler = try #require(store.surface.tmuxSplitShortcutHandler)
        handler(.down)
        await waitUntilMainActor { calls.load().count == 1 }
        await waitUntilMainActor {
            store.surface.tmuxSplitErrorMessage != nil
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
        #expect(store.surface.tmuxSplitErrorMessage?.contains(
            "release-work"
        ) == true)
        #expect(store.surface.tmuxSplitErrorMessage?.contains(
            "no space for new pane"
        ) == true)
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
            sshConnectionArgumentsProvider: { _ in
                SSHConnectionArgumentsSnapshot(
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
            ["-F", "/dev/null", "-o", "HostName=second.example.test"],
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
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("tmux.exe") }
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

        #expect(store.surface.tmuxSplitShortcutHandler == nil)
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
        let handler = try #require(store.surface.tmuxSplitShortcutHandler)
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
        let handler = try #require(store.surface.tmuxSplitShortcutHandler)
        handler(.right)
        await waitUntilMainActor { events.load() == ["start-right"] }
        handler(.down)

        coordinator.detach(hostID: hostID, name: "cancelled")

        await waitUntilMainActor { events.load().count == 2 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(events.load() == ["start-right", "cancel-right"])
    }

    @Test("failed client binding can be retried without queuing a split")
    func failedClientBindingCanBeRetried() async throws {
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
                    if attempt == 1 {
                        return (1, "no clients yet")
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
            name: "appearing",
            host: .local,
            sessionIdentity: coordinatorSplitIdentity
        )

        await waitUntilMainActor { readyCount == 1 }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { clientLookups.load() == 1 }
        #expect(coordinator.supportsPaneSplitting(handle))
        let handler = try #require(store.surface.tmuxSplitShortcutHandler)
        handler(.right)
        await waitUntilMainActor { readyCount == 2 }
        #expect(store.surface.tmuxSplitErrorMessage == nil)
        #expect(splitCommands.load() == 0)
        handler(.down)
        await waitUntilMainActor { splitCommands.load() == 1 }
        #expect(clientLookups.load() == 3)
        #expect(store.surface.tmuxSplitErrorMessage == nil)
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
        let handler = try #require(store.surface.tmuxSplitShortcutHandler)
        handler(.right)
        await waitUntilMainActor { splitCommands.load() == 1 }
        handler(.down)
        await waitUntilMainActor {
            store.surface.tmuxSplitErrorMessage != nil
                || splitCommands.load() == 2
        }

        #expect(clientLookups.load() == 3)
        #expect(splitCommands.load() == 1)
        #expect(store.surface.tmuxSplitErrorMessage?.contains(
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
        let handler = try #require(store.surface.tmuxSplitShortcutHandler)
        handler(.right)
        await waitUntilMainActor { splitCommands.load().count == 1 }
        handler(.down)
        await waitUntilMainActor {
            store.surface.tmuxSplitErrorMessage != nil
                || splitCommands.load().count == 2
        }

        #expect(clientLookups.load() == 3)
        #expect(splitCommands.load().count == 2)
        #expect(splitCommands.load().last?.contains("'%10'") == true)
        #expect(store.surface.tmuxSplitErrorMessage == nil)
    }

    @Test("endpoint changes replace provisioning and active handles")
    func endpointChangesReplaceHandles() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") }
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
        let coordinator = NativeTmuxSessionCoordinator(
            terminalCoordinator: store,
            tmuxPathProvider: { successfulTmuxResolution("/usr/bin/tmux") },
            remoteTmuxPathProvider: { _, _ in successfulTmuxResolution("/usr/bin/tmux") },
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
