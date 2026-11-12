#if canImport(GhosttyKit)
import AppKit
import Foundation
import GhosthubPersistence
import GhosthubTestSupport
import Testing
import GhosthubHerdr
import GhosthubTerminal
import GhosthubTransport
import GhosthubWorkspace
import Synchronization
import XCTest
@testable import GhosthubApp

/// Uses XCTest's AppKit run loop to test real window activation and keyboard routing.
@MainActor
final class WorkspaceHerdrFocusTests: XCTestCase {
    func testReselectingRetainedTerminalRestoresFocus() async throws {
        try await checkFocus(.reselect)
    }
    func testSuccessfulValidationReleasesPreviousTerminal() async throws {
        try await checkFocus(.success)
    }
    func testFailedValidationReleasesPreviousTerminal() async throws {
        try await checkFocus(.failure)
    }
    func testCancelledValidationReleasesPreviousTerminal() async throws {
        try await checkFocus(.cancellation)
    }
    func testNavigationElsewhereDoesNotRestoreFocus() async throws {
        try await checkFocus(.navigateAway)
    }

    enum FocusValidationOutcome: Sendable {
        case reselect, success, failure, cancellation, navigateAway
    }

    private func checkFocus(_ outcome: FocusValidationOutcome) async throws {
        let database = try WorkspaceDatabase.inMemory()
        let hostID = UUID()
        let sessions = ["alpha", "beta"].map {
            HerdrSessionSummary(name: $0, isDefault: false, state: .running)
        }
        let snapshot = WorkspaceSnapshot.fixture(hosts: [.fixture(
            id: hostID,
            herdrSessions: sessions
        )])
        let blocked = Mutex(false)
        let probeStarted = Mutex(false)
        let releaseProbe = AsyncGate()
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try "#!/bin/sh\nexec /bin/cat\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let store = TerminalSurfaceCoordinator(runtime: .shared)
        var surface: TerminalSurfaceView?
        store.onSurfaceCreated = { _, view in surface = view }
        let model = try makeModel(
            database: database, localHostID: hostID,
            snapshot: snapshot, nativeHerdrSurfaceStore: store,
            nativeHerdrPathProvider: { _ in .success(script.path) },
            herdrPaneSplitCapabilityProvider: { _, _, _, _ in .success(nil) },
            herdrSessionValidationDiscovery: { _, _ in
                let shouldBlock = blocked.withLock { value in
                    let result = value
                    value = false
                    return result
                }
                if shouldBlock {
                    probeStarted.withLock { $0 = true }
                    await releaseProbe.wait()
                    if outcome == .failure {
                        return .unavailable
                    }
                }
                return .available(sessions)
            }
        )
        let first = WorkspaceHerdrSessionSelection(hostID: hostID, name: "alpha")
        let second = WorkspaceHerdrSessionSelection(hostID: hostID, name: "beta")
        try await model.openBorrowedHerdrSession(first)
        await waitUntilMainActor {
            model.prepareActiveBorrowedHerdrSurface()
            return surface != nil
        }
        guard let input = surface else {
            await model.shutdown()
            XCTFail("No real terminal surface was created")
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "Ghosthub Herdr focus regression"
        window.contentView = input
        addTeardownBlock { @MainActor in
            await model.shutdown()
            await input.shutdown()
        }
        defer { window.orderOut(nil) }
        guard activate(window) else {
            await model.shutdown()
            await input.shutdown()
            throw XCTSkip("Requires an active AppKit window")
        }
        model.workspaceWindow = window
        XCTAssertTrue(window.makeFirstResponder(input))
        try await model.openBorrowedHerdrSession(first)
        XCTAssertTrue(window.firstResponder === input)

        blocked.withLock { $0 = true }
        let opening = Task { try await model.openBorrowedHerdrSession(second) }
        await waitUntilMainActor { probeStarted.withLock { $0 } }
        XCTAssertTrue(probeStarted.withLock { $0 })
        XCTAssertTrue(window.firstResponder !== input)
        XCTAssertTrue(model.activeBorrowedHerdrSelection == first)

        let otherWindow = NSWindow(
            contentRect: NSRect(x: 50, y: 50, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        otherWindow.makeKeyAndOrderFront(nil)
        pumpEvents()
        XCTAssertTrue(otherWindow.isKeyWindow)
        window.makeKeyAndOrderFront(nil)
        pumpEvents()
        otherWindow.orderOut(nil)
        XCTAssertTrue(window.isKeyWindow && NSApplication.shared.isActive)
        XCTAssertTrue(window.firstResponder !== input)
        window.makeFirstResponder(nil)
        let command = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "=",
            charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24
        ))
        _ = window.performKeyEquivalent(with: command)
        XCTAssertTrue(window.firstResponder !== input)
        window.makeFirstResponder(nil)

        switch outcome {
        case .reselect:
            model.selectFromUser(WorkspaceSelection(selectedHostID: hostID))
            try await model.openBorrowedHerdrSession(first)
            XCTAssertTrue(window.firstResponder === input)
        case .cancellation:
            opening.cancel()
        case .navigateAway:
            model.selectFromUser(WorkspaceSelection(selectedHostID: hostID))
        case .success, .failure:
            break
        }
        releaseProbe.open()
        do {
            try await opening.value
            XCTAssertTrue(outcome == .success)
        } catch HerdrSessionPresentationError.unavailable {
            XCTAssertTrue(outcome == .failure)
        } catch is CancellationError {
            XCTAssertTrue(outcome == .reselect || outcome == .cancellation || outcome ==
                .navigateAway)
        } catch {
            XCTFail("Unexpected validation error: \(error)")
        }
        switch outcome {
        case .success:
            XCTAssertTrue(model.activeBorrowedHerdrSelection == second)
            await waitUntilMainActor {
                model.prepareActiveBorrowedHerdrSurface()
                return surface !== input
            }
            let successor = try XCTUnwrap(surface)
            addTeardownBlock { @MainActor in await successor.shutdown() }
            window.contentView = successor
            successor.requestKeyboardFocus()
            XCTAssertTrue(window.firstResponder === successor)
        case .failure, .cancellation:
            XCTAssertTrue(model.activeBorrowedHerdrSelection == first)
            XCTAssertTrue(input.acceptsFirstResponder)
            input.requestKeyboardFocus()
            XCTAssertTrue(window.firstResponder === input)
        case .reselect:
            XCTAssertTrue(model.activeBorrowedHerdrSelection == first)
            XCTAssertTrue(input.acceptsFirstResponder)
            XCTAssertTrue(window.firstResponder === input)
        case .navigateAway:
            XCTAssertTrue(window.firstResponder !== input)
        }
        await model.shutdown()
        await input.shutdown()
    }

    /// Returning to the Zellij session that is still on screen must give it
    /// back the keyboard that a superseded Herdr open took away.
    func testReturningToZellijDuringHerdrValidationRestoresFocus() async throws {
        let database = try WorkspaceDatabase.inMemory()
        let hostID = UUID()
        let herdrSessions = [
            HerdrSessionSummary(name: "agent", isDefault: false, state: .running),
        ]
        let snapshot = WorkspaceSnapshot.fixture(hosts: [.fixture(
            id: hostID,
            herdrSessions: herdrSessions,
            herdrAvailable: true,
            zellijSessions: [ZellijSessionSummary(name: "editor")],
            zellijAvailable: true
        )])
        let probeStarted = Mutex(false)
        let releaseProbe = AsyncGate()
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try "#!/bin/sh\nexec /bin/cat\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let zellijStore = TerminalSurfaceCoordinator(runtime: .shared)
        var surface: TerminalSurfaceView?
        zellijStore.onSurfaceCreated = { _, view in surface = view }
        let model = try makeModel(
            database: database, localHostID: hostID,
            snapshot: snapshot,
            nativeHerdrSurfaceStore: RecordingNativeSessionSurfaceStore(),
            nativeZellijSurfaceStore: zellijStore,
            nativeHerdrPathProvider: { _ in .success(script.path) },
            nativeZellijPathProvider: { _ in .success(script.path) },
            zellijSessionValidationDiscovery: { _, _ in .available(["editor"]) },
            herdrSessionValidationDiscovery: { _, _ in
                probeStarted.withLock { $0 = true }
                await releaseProbe.wait()
                return .available(herdrSessions)
            }
        )
        let zellij = WorkspaceZellijSessionSelection(hostID: hostID, name: "editor")
        model.openBorrowedZellijSession(zellij)
        await waitUntilMainActor {
            model.prepareActiveBorrowedZellijSurface()
            return surface != nil
        }
        guard let input = surface else {
            await model.shutdown()
            XCTFail("No real terminal surface was created")
            return
        }
        addTeardownBlock { @MainActor in
            await model.shutdown()
            await input.shutdown()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "Ghosthub Zellij focus regression"
        window.contentView = input
        defer { window.orderOut(nil) }
        guard activate(window) else {
            throw XCTSkip("Requires an active AppKit window")
        }
        model.workspaceWindow = window
        XCTAssertTrue(window.makeFirstResponder(input))

        let opening = Task {
            try await model.openBorrowedHerdrSession(.init(hostID: hostID, name: "agent"))
        }
        await waitUntilMainActor { probeStarted.withLock { $0 } }
        XCTAssertTrue(probeStarted.withLock { $0 })
        XCTAssertTrue(window.firstResponder !== input)
        XCTAssertTrue(model.activeBorrowedZellijSelection == zellij)

        model.selectFromUser(WorkspaceSelection(selectedHostID: hostID))
        model.openBorrowedZellijSession(zellij)
        XCTAssertTrue(window.firstResponder === input)

        releaseProbe.open()
        do {
            try await opening.value
            XCTFail("The superseded Herdr open completed")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected validation error: \(error)")
        }
        XCTAssertTrue(model.activeBorrowedZellijSelection == zellij)
        XCTAssertNil(model.activeBorrowedHerdrSelection)
        XCTAssertTrue(window.firstResponder === input)
    }

    /// Requires actual AppKit activation, including event dispatch, rather
    /// than a window subclass or a synthetic didBecomeKey notification.
    private func activate(_ window: NSWindow) -> Bool {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        NSApplication.shared.unhide(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(window.isKeyWindow && NSApplication.shared.isActive) {
            pumpEvents()
        }
        return window.isKeyWindow && NSApplication.shared.isActive
    }

    private func pumpEvents() {
        let deadline = Date().addingTimeInterval(0.05)
        while Date() < deadline,
              let event = NSApplication.shared.nextEvent(
                  matching: .any, until: deadline, inMode: .default, dequeue: true
              ) {
            NSApplication.shared.sendEvent(event)
        }
    }
}
#endif
