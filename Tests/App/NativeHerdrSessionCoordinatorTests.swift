import Foundation
import GhosthubHerdr
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Native Herdr presentation", .serialized)
@MainActor
struct NativeHerdrSessionCoordinatorTests {
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
        (UInt32(0), BorrowedHerdrAttachmentClosure.detached),
        (UInt32(255), BorrowedHerdrAttachmentClosure.processExited(code: 255)),
        (UInt32(9), BorrowedHerdrAttachmentClosure.processExited(code: 9)),
    ])
    func remoteExitClassification(
        recordedCode: UInt32,
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
        close(false, 0)

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

    private var remoteHost: CommandHost {
        .ssh(.init(
            user: "dev",
            hostname: "build.example.test",
            port: 2222
        ))
    }

    private func makeCoordinator(
        store: RecordingNativeSessionSurfaceStore,
        statusDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    ) -> NativeHerdrSessionCoordinator {
        NativeHerdrSessionCoordinator(
            terminalCoordinator: store,
            herdrPathProvider: { _ in .success("/opt/homebrew/bin/herdr") },
            sshConnectionArgumentsProvider: { _ in
                [
                    "-o", "ControlPath=/tmp/ghosthub-test-control",
                    "-o", "StrictHostKeyChecking=yes",
                ]
            },
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

private enum HerdrSurfaceTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "Herdr surface rejected" }
}
