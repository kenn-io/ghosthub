import Foundation
@preconcurrency import Dispatch
import GhosthubHerdr
import GhosthubTransport
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

@Suite("Native Herdr presentation", .serialized)
@MainActor
struct NativeHerdrSessionCoordinatorTests {
    @Test("launch mode is visible while Herdr provisioning is in flight")
    func provisioningPublishesLaunchMode() async {
        let started = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let coordinator = NativeHerdrSessionCoordinator(
            terminalCoordinator: RecordingNativeSessionSurfaceStore(),
            herdrPathProvider: { _, _ in
                started.withLock { $0 = true }
                release.wait()
                return .success("/usr/bin/herdr")
            }
        )
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: .local,
            launchMode: .attachExisting
        )
        await waitUntilMainActor { started.withLock { $0 } }

        #expect(coordinator.attachmentLaunchMode(handle) == .attachExisting)
        #expect(coordinator.attachmentAuthority(handle) == nil)
        release.signal()
    }

    @Test("completed authority retains the attachment SSH route")
    func completedAuthorityRetainsRoute() async throws {
        let snapshot = SSHConnectionArgumentsSnapshot(arguments: [
            "-F", "/tmp/frozen-config", "build.example.test",
        ])
        let coordinator = NativeHerdrSessionCoordinator(
            terminalCoordinator: RecordingNativeSessionSurfaceStore(),
            herdrPathProvider: { _, _ in .success("/usr/bin/herdr") },
            sshConnectionArgumentsProvider: { _ in snapshot }
        )
        var ready = false
        coordinator.onSurfaceReady = { _ in ready = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: remoteHost,
            launchMode: .launchOrAttach
        )
        await waitUntilMainActor { ready }

        let authority = try #require(
            coordinator.attachmentAuthority(handle)
        )
        #expect(authority.host == remoteHost)
        #expect(authority.launchMode == .launchOrAttach)
        #expect(authority.sshConnectionSnapshot.cacheKey == snapshot.cacheKey)
    }

    @Test("same route reuses a handle and route changes replace it")
    func handleIdentityTracksRoute() {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = makeCoordinator(store: store)
        let hostID = UUID()
        let firstRoute = CommandHost.ssh(.init(
            user: "dev",
            hostname: "old.example.test",
            port: nil
        ))
        let first = coordinator.attach(
            hostID: hostID,
            name: "api",
            host: firstRoute
        )
        let reused = coordinator.attach(
            hostID: hostID,
            name: "api",
            host: firstRoute
        )
        let replacement = coordinator.attach(
            hostID: hostID,
            name: "api",
            host: .ssh(.init(
                user: "dev",
                hostname: "new.example.test",
                port: 2222
            ))
        )

        #expect(reused == first)
        #expect(replacement.id != first.id)
        #expect(store.removedKeys.contains {
            $0.target == .herdrSession && $0.leafID == first.surfaceID
        })
    }

    @Test("local attachment builds the Herdr client and reports connection")
    func localAttachment() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = makeCoordinator(store: store)
        var states: [ConnectionState] = []
        var ready = false
        coordinator.onStateChanged = { _, state in states.append(state) }
        coordinator.onSurfaceReady = { _ in ready = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: .local
        )

        #expect(states == [.connecting])
        await waitUntilMainActor { ready }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { states.contains(.connected) }

        let command = try #require(store.requestedConfigurations.last?.command)
        #expect(command.contains("/opt/homebrew/bin/herdr"))
        #expect(command.contains("session"))
        #expect(command.contains("attach"))
        #expect(command.contains("api"))
        #expect(store.requestedKeys.last?.target == .herdrSession)
        #expect(!store.surface.blocksClipboardReads)
    }

    @Test("launch-or-attach mode reaches the terminal command")
    func launchOrAttach() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = makeCoordinator(store: store)
        var ready = false
        coordinator.onSurfaceReady = { _ in ready = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "review",
            host: .local,
            launchMode: .launchOrAttach
        )
        await waitUntilMainActor { ready }

        _ = coordinator.surface(handle: handle)
        let command = try #require(store.requestedConfigurations.last?.command)
        #expect(command.contains("--session"))
        #expect(command.contains("review"))
        #expect(!command.contains("'session' 'attach'"))
    }

    @Test("local client exit classification", arguments: [
        (UInt32(0), BorrowedHerdrAttachmentClosure.detached),
        (UInt32(7), BorrowedHerdrAttachmentClosure.processExited(code: 7)),
    ])
    func localExitClassification(
        exitCode: UInt32,
        expected: BorrowedHerdrAttachmentClosure
    ) async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = makeCoordinator(store: store)
        var ready = false
        coordinator.onSurfaceReady = { _ in ready = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: .local
        )
        await waitUntilMainActor { ready }
        _ = coordinator.surface(handle: handle)

        let close = try #require(store.surface.closeObservers[handle.id])
        close(false, exitCode)

        #expect(coordinator.attachmentClosure(handle) == expected)
    }

    @Test("remote status controls closure classification", arguments: [
        (UInt32(0), false, BorrowedHerdrAttachmentClosure.detached),
        (UInt32(255), false, BorrowedHerdrAttachmentClosure.processExited(code: 255)),
        (UInt32(255), true, BorrowedHerdrAttachmentClosure.processExited(code: 255)),
        (UInt32(9), false, BorrowedHerdrAttachmentClosure.processExited(code: 9)),
    ])
    func remoteExitClassification(
        recordedCode: UInt32,
        processAlive: Bool,
        expected: BorrowedHerdrAttachmentClosure
    ) async throws {
        let directory = temporaryStatusDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = makeCoordinator(
            store: store,
            statusDirectory: directory
        )
        var ready = false
        coordinator.onSurfaceReady = { _ in ready = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: remoteHost
        )
        await waitUntilMainActor { ready }
        _ = coordinator.surface(handle: handle)
        let statusFile = try #require(statusFiles(in: directory).first)
        try "\(recordedCode)\n".write(
            to: statusFile,
            atomically: true,
            encoding: .utf8
        )

        let close = try #require(store.surface.closeObservers[handle.id])
        close(processAlive, 0)

        #expect(coordinator.attachmentClosure(handle) == expected)
        #expect(!FileManager.default.fileExists(atPath: statusFile.path))
    }

    @Test("remote attachment uses pooled SSH and protected status files")
    func remoteTransportConfiguration() async throws {
        let directory = temporaryStatusDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = makeCoordinator(
            store: store,
            statusDirectory: directory
        )
        var ready = false
        coordinator.onSurfaceReady = { _ in ready = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: remoteHost
        )
        await waitUntilMainActor { ready }

        let directoryMode = try posixMode(directory)
        let statusFile = try #require(statusFiles(in: directory).first)
        #expect(directoryMode == 0o700)
        #expect(try posixMode(statusFile) == 0o600)
        _ = coordinator.surface(handle: handle)
        let command = try #require(store.requestedConfigurations.last?.command)
        #expect(command.contains("ControlPath=/tmp/ghosthub-test-control"))
        #expect(command.contains("StrictHostKeyChecking=yes"))
        #expect(command.contains(statusFile.lastPathComponent))
        #expect(store.surface.blocksClipboardReads)

        coordinator.detach(hostID: handle.hostID, name: handle.name)
        #expect(!FileManager.default.fileExists(atPath: statusFile.path))
    }

    @Test("launch failure never reports connected")
    func launchFailure() async {
        let store = RecordingNativeSessionSurfaceStore(
            launchError: HerdrSurfaceTestError.rejected
        )
        let coordinator = makeCoordinator(store: store)
        var states: [ConnectionState] = []
        var ready = false
        coordinator.onStateChanged = { _, state in states.append(state) }
        coordinator.onSurfaceReady = { _ in ready = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: .local
        )
        await waitUntilMainActor { ready }

        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor {
            states.contains {
                if case .disconnected = $0 {
                    true
                } else {
                    false
                }
            }
        }
        #expect(coordinator.attachmentClosure(handle) == .launchFailed)
        #expect(!states.contains(.connected))
    }

    @Test("path-resolution failure is retryable")
    func pathResolutionFailureIsRetryable() async {
        let store = RecordingNativeSessionSurfaceStore()
        let resolutionCount = Mutex(0)
        let coordinator = NativeHerdrSessionCoordinator(
            terminalCoordinator: store,
            herdrPathProvider: { _, _ in
                let count = resolutionCount.withLock { count in
                    count += 1
                    return count
                }
                return count == 1
                    ? .failure(.unavailable)
                    : .success("/new/bin/herdr")
            }
        )
        var disconnected = false
        var ready = false
        coordinator.onStateChanged = { _, state in
            if case .disconnected = state {
                disconnected = true
            }
        }
        coordinator.onSurfaceReady = { _ in ready = true }
        let hostID = UUID()
        let failed = coordinator.attach(
            hostID: hostID,
            name: "api",
            host: .local,
            launchMode: .launchOrAttach
        )
        await waitUntilMainActor { disconnected }

        #expect(coordinator.attachmentClosure(failed) == .launchFailed)

        let retried = coordinator.attach(
            hostID: hostID,
            name: "api",
            host: .local,
            launchMode: .launchOrAttach
        )
        await waitUntilMainActor { ready }
        _ = coordinator.surface(handle: retried)

        #expect(resolutionCount.withLock { $0 } == 2)
        let retryCommand = store.requestedConfigurations.last?.command ?? ""
        #expect(retryCommand.contains(
            "/new/bin/herdr"
        ) == true)
    }

    @Test("fresh attachment attempts resolve the Herdr executable again")
    func freshAttachmentReresolvesExecutable() async {
        let store = RecordingNativeSessionSurfaceStore()
        let resolutionCount = Mutex(0)
        let coordinator = NativeHerdrSessionCoordinator(
            terminalCoordinator: store,
            herdrPathProvider: { _, _ in
                let count = resolutionCount.withLock { count in
                    count += 1
                    return count
                }
                return .success(count == 1
                    ? "/old/bin/herdr"
                    : "/new/bin/herdr")
            }
        )
        var readyHandles: Set<UUID> = []
        coordinator.onSurfaceReady = { readyHandles.insert($0.id) }
        let hostID = UUID()
        let first = coordinator.attach(
            hostID: hostID,
            name: "api",
            host: .local
        )
        await waitUntilMainActor { readyHandles.contains(first.id) }
        _ = coordinator.surface(handle: first)
        coordinator.detach(hostID: hostID, name: "api")

        let retry = coordinator.attach(
            hostID: hostID,
            name: "api",
            host: .local
        )
        await waitUntilMainActor { readyHandles.contains(retry.id) }
        _ = coordinator.surface(handle: retry)

        #expect(resolutionCount.withLock { $0 } == 2)
        let retryCommand = store.requestedConfigurations.last?.command ?? ""
        #expect(retryCommand.contains(
            "/new/bin/herdr"
        ) == true)
    }

    @Test("Windows is rejected before surface creation")
    func windowsIsRejected() async {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = makeCoordinator(store: store)
        var states: [ConnectionState] = []
        coordinator.onStateChanged = { _, state in states.append(state) }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: .ssh(.init(
                user: "dev",
                hostname: "windows.example.test",
                port: nil,
                platform: .windows
            ))
        )
        await waitUntilMainActor { states.count >= 2 }

        _ = coordinator.surface(handle: handle)
        #expect(store.requestedConfigurations.isEmpty)
        #expect(!coordinator.hasLaunched(handle))
        #expect(states.contains {
            if case .disconnected = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test("shutdown removes pending remote status and client surface")
    func shutdownCleansAttachment() async throws {
        let directory = temporaryStatusDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = makeCoordinator(
            store: store,
            statusDirectory: directory
        )
        var ready = false
        coordinator.onSurfaceReady = { _ in ready = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: remoteHost
        )
        await waitUntilMainActor { ready }
        let statusFile = try #require(statusFiles(in: directory).first)

        coordinator.shutdown()

        #expect(!FileManager.default.fileExists(atPath: statusFile.path))
        #expect(store.removedKeys.contains {
            $0.target == .herdrSession && $0.leafID == handle.surfaceID
        })
    }

    @Test("capability binding installs a frozen-socket split handler")
    func paneSplitCapability() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let receivedRoute = Mutex<(
            CommandHost,
            [String],
            String,
            String
        )?>(nil)
        let splitCommands = Mutex<[String]>([])
        let coordinator = makeCoordinator(
            store: store,
            capabilityProvider: { host, arguments, path, name in
                receivedRoute.withLock {
                    $0 = (host, arguments, path, name)
                }
                return .success(testHerdrPaneSplitCapability(name: name))
            },
            paneSplitter: HerdrPaneSplitter { _, _, command in
                splitCommands.withLock { $0.append(command) }
                return (0, "")
            }
        )
        var ready = false
        coordinator.onSurfaceReady = { _ in ready = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: remoteHost
        )
        await waitUntilMainActor { ready }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor {
            coordinator.supportsPaneSplitting(handle)
        }

        let route = try #require(receivedRoute.withLock { $0 })
        #expect(route.0 == remoteHost)
        #expect(route.1.contains("ControlPath=/tmp/ghosthub-test-control"))
        #expect(route.2 == "/opt/homebrew/bin/herdr")
        #expect(route.3 == "api")
        #expect(store.surface.paneSplitShortcutHandler != nil)

        store.surface.hasEffectiveKeyboardFocus = false
        coordinator.requestPaneSplit(
            .right,
            handle: handle,
            requiresKeyboardFocus: true
        )
        #expect(splitCommands.withLock(\.count) == 0)
        store.surface.hasEffectiveKeyboardFocus = true
        coordinator.requestPaneSplit(
            .right,
            handle: handle,
            requiresKeyboardFocus: true
        )
        await waitUntilMainActor { splitCommands.withLock(\.count) == 1 }
        #expect(splitCommands.withLock { $0[0] }.contains(
            "HERDR_SOCKET_PATH='/tmp/api/herdr.sock'"
        ))
    }

    @Test("incapable probes do not block ordinary attachment")
    func incapableProbeStillAttaches() async {
        let store = RecordingNativeSessionSurfaceStore()
        let coordinator = makeCoordinator(
            store: store,
            capabilityProvider: { _, _, _, _ in
                .failure(.malformedVersion)
            }
        )
        var states: [ConnectionState] = []
        var ready = false
        coordinator.onStateChanged = { _, state in states.append(state) }
        coordinator.onSurfaceReady = { _ in ready = true }
        let handle = coordinator.attach(
            hostID: UUID(),
            name: "api",
            host: .local
        )
        await waitUntilMainActor { ready }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor { states.contains(.connected) }

        #expect(!coordinator.supportsPaneSplitting(handle))
        #expect(store.surface.paneSplitShortcutHandler == nil)
    }

    @Test("split requests serialize and detaching abandons queued work")
    func splitQueueCancellation() async throws {
        let store = RecordingNativeSessionSurfaceStore()
        let starts = Mutex(0)
        let firstFinished = Mutex(false)
        let firstRelease = DispatchSemaphore(value: 0)
        let coordinator = makeCoordinator(
            store: store,
            capabilityProvider: { _, _, _, name in
                .success(testHerdrPaneSplitCapability(name: name))
            },
            paneSplitter: HerdrPaneSplitter { _, _, _ in
                let index = starts.withLock { value in
                    value += 1
                    return value
                }
                if index == 1 {
                    firstRelease.wait()
                    firstFinished.withLock { $0 = true }
                }
                return (9, "socket closed")
            }
        )
        var ready = false
        coordinator.onSurfaceReady = { _ in ready = true }
        let hostID = UUID()
        let handle = coordinator.attach(
            hostID: hostID,
            name: "api",
            host: .local
        )
        await waitUntilMainActor { ready }
        _ = coordinator.surface(handle: handle)
        await waitUntilMainActor {
            coordinator.supportsPaneSplitting(handle)
        }
        let handler = try #require(store.surface.paneSplitShortcutHandler)

        handler(.right)
        handler(.down)
        await waitUntilMainActor { starts.withLock { $0 } == 1 }
        coordinator.detach(hostID: hostID, name: "api")
        firstRelease.signal()
        await waitUntilMainActor { firstFinished.withLock { $0 } }

        #expect(starts.withLock { $0 } == 1)
        #expect(store.surface.paneSplitErrorMessage == nil)
    }

    private var remoteHost: CommandHost {
        .ssh(.init(
            user: "dev",
            hostname: "build.example.test",
            port: 2222
        ))
    }

    private func makeCoordinator(
        store: RecordingNativeSessionSurfaceStore,
        capabilityProvider: @escaping NativeHerdrSessionCoordinator
            .PaneSplitCapabilityProvider = { _, _, _, _ in .success(nil) },
        paneSplitter: HerdrPaneSplitter = HerdrPaneSplitter(),
        statusDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    ) -> NativeHerdrSessionCoordinator {
        NativeHerdrSessionCoordinator(
            terminalCoordinator: store,
            herdrPathProvider: { _, _ in .success("/opt/homebrew/bin/herdr") },
            sshConnectionArgumentsProvider: { _ in
                SSHConnectionArgumentsSnapshot(arguments: [
                    "-o", "ControlPath=/tmp/ghosthub-test-control",
                    "-o", "StrictHostKeyChecking=yes",
                ])
            },
            paneSplitCapabilityProvider: capabilityProvider,
            paneSplitter: paneSplitter,
            remoteExitStatusDirectory: statusDirectory
        )
    }

    private func temporaryStatusDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
    }

    private func statusFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    private func posixMode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private func testHerdrPaneSplitCapability(
    name: String
) -> HerdrPaneSplitCapability {
    HerdrPaneSplitCapability(
        version: .paneSplitting,
        session: HerdrSessionRecord(
            name: name,
            isDefault: false,
            state: .running,
            sessionDirectory: "/tmp/\(name)",
            socketPath: "/tmp/\(name)/herdr.sock"
        )
    )
}

private enum HerdrSurfaceTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "Herdr surface rejected" }
}
