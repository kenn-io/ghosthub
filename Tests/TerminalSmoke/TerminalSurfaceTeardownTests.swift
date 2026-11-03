import AppKit
import Darwin
import Foundation
import XCTest
@testable import GhosthubTerminal

/// Rewrites the window title as fast as the shell can, so every pty read
/// posts surface messages into the app mailbox.
private let titleSpamCommand =
    "/bin/sh -c 'i=0; while :; do i=$((i+1)); printf \"\\033]0;teardown-%s\\007\" \"$i\"; done'"

@MainActor
final class TerminalSurfaceTeardownTests: XCTestCase {
    /// Retained across the suite so ghostty_app_free never runs while a
    /// surface from this suite is still alive.
    private static var retainedRuntime: LibghosttyRuntime?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessLibghosttyReady()
    }

    private func retainedRuntime() -> LibghosttyRuntime {
        if Self.retainedRuntime == nil {
            let (pipeline, _) = makeIsolatedSurfacePipeline()
            Self.retainedRuntime = LibghosttyRuntime(pipeline: pipeline)
        }
        return Self.retainedRuntime!
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Keeps the main thread from ticking the app, so nothing drains the
    /// app mailbox, as when the main thread is inside a surface free.
    private func blockMainThread(seconds: Double) {
        usleep(useconds_t(seconds * 1_000_000))
    }

    /// Regression test for #269. A surface free used to join the surface's
    /// threads on the main thread while its pty reader was blocked pushing
    /// into the app mailbox that only the main thread drains. The reader
    /// stopped reading the pty, the exiting child never finished, and the
    /// free never returned.
    func testFreeingSurfaceWithBackedUpAppMailboxReturns() async throws {
        let appHandle = try XCTUnwrap(retainedRuntime().unsafeAppHandle)
        let view = TerminalSurfaceView(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: titleSpamCommand
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.sizeDidChange(CGSize(width: 800, height: 600))
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }

        waitUntil { view.title.hasPrefix("teardown-") }
        XCTAssertTrue(
            view.title.hasPrefix("teardown-"),
            "expected the child to be rewriting the title, got "
                + view.title.debugDescription
        )

        blockMainThread(seconds: 0.5)

        // A main thread stuck in ghostty_surface_free can never report a
        // failure, so end the run instead of hanging until the CI timeout.
        let watchdog = DispatchWorkItem {
            fatalError("ghostty_surface_free did not return within 30 seconds")
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + 30,
            execute: watchdog
        )
        await view.shutdown()
        watchdog.cancel()

        XCTAssertNil(view.surfaceHandle)
    }
}
