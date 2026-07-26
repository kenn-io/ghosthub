import AppKit
import Foundation
import GhosttyKit
import XCTest
@testable import GhosthubTerminal

/// The silent child keeps libghostty's exec backend alive while all real
/// output arrives via ghostty_surface_inject_output (the fantastty pattern).
private let silentChildCommand = "/bin/sh -c 'stty raw -echo 2>/dev/null; exec /bin/cat >/dev/null'"

@MainActor
final class TmuxInjectionSmokeTests: XCTestCase {
    /// Retained across the entire test suite so ghostty_app_free is
    /// never called while deferred ghostty_surface_free tasks are
    /// still pending.
    private static var retainedRuntime: LibghosttyRuntime?
    /// Windows must stay alive for the duration of the surface's
    /// lifetime, or the surface tears down before the test can
    /// exercise it.
    private static var retainedWindows: [NSWindow] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessLibghosttyReady()
    }

    private func retainedRuntime() -> LibghosttyRuntime {
        if Self.retainedRuntime == nil {
            let (pipeline, _) = makeIsolatedPipeline()
            Self.retainedRuntime = LibghosttyRuntime(pipeline: pipeline)
        }
        return Self.retainedRuntime!
    }

    private func makeSurface(command: String) -> TerminalSurfaceView {
        let (view, window) = makeUnretainedSurface(command: command)
        Self.retainedWindows.append(window)
        return view
    }

    /// Same setup as `makeSurface`, but the caller owns the window's
    /// lifetime instead of it being retained for the whole test suite.
    /// Used to force a view's teardown mid-test (e.g. to exercise the
    /// deferred `deinit` cleanup path) while a sibling view stays alive.
    private func makeUnretainedSurface(
        command: String
    ) -> (view: TerminalSurfaceView, window: NSWindow) {
        let appHandle = retainedRuntime().unsafeAppHandle!
        let view = TerminalSurfaceView(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(command: command)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.focusDidChange(true)
        view.sizeDidChange(CGSize(width: 800, height: 600))
        return (view, window)
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if condition() {
                return
            }
        }
    }

    private func readViewportText(
        from view: TerminalSurfaceView
    ) -> String {
        guard let surface = view.surfaceHandle else {
            return ""
        }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return ""
        }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    func testInjectedOutputRendersInViewport() {
        let view = makeSurface(command: silentChildCommand)
        waitUntil(timeout: 5.0) { view.error == nil && view.surfaceHandle != nil }

        let marker = "INJECT-OK-7261"
        XCTAssertTrue(view.injectOutput(Data(marker.utf8)))
        waitUntil(timeout: 5.0) { self.readViewportText(from: view).contains(marker) }
        XCTAssertTrue(readViewportText(from: view).contains(marker))
    }

    func testChildWriteMirrorsQueryResponses() throws {
        let view = makeSurface(command: silentChildCommand)
        waitUntil(timeout: 5.0) { view.error == nil && view.surfaceHandle != nil }

        var received = Data()
        view.onChildWrite = { received.append($0) }

        // DSR cursor-position query: the terminal answers ESC[<row>;<col>R
        // toward its child; the mirror must hand it to onChildWrite.
        XCTAssertTrue(view.injectOutput(Data("\u{1b}[6n".utf8)))
        waitUntil(timeout: 5.0) {
            String(data: received, encoding: .utf8)?.contains("R") == true
        }
        let text = try XCTUnwrap(String(data: received, encoding: .utf8))
        XCTAssertTrue(
            text.contains("\u{1b}["),
            "expected a CSI cursor report, got \(text.debugDescription)"
        )
    }

    /// Regression test for callback misdelivery via reused view
    /// addresses. Each surface now hands libghostty a uniquely allocated
    /// `SurfaceCallbackToken` as its `userdata` (not the reusable view
    /// object address), and the token is kept alive until after
    /// `ghostty_surface_free` returns. Because the token is unique per
    /// view and strongly held until callbacks are impossible, tearing
    /// down one view can never disturb a sibling's live `onChildWrite`
    /// delivery — this test pins that end-to-end behaviour.
    func testSurvivingViewResolvesAfterSiblingTeardown() throws {
        let survivor = makeSurface(command: silentChildCommand)
        waitUntil(timeout: 5.0) { survivor.error == nil && survivor.surfaceHandle != nil }

        var dyingSurfaceIdentity: UInt = 0
        autoreleasepool {
            let (dying, dyingWindow) = makeUnretainedSurface(
                command: silentChildCommand
            )
            waitUntil(timeout: 5.0) {
                dying.error == nil && dying.surfaceHandle != nil
            }

            guard let dyingHandle = dying.surfaceHandle else {
                XCTFail("expected the dying view to have a surface handle")
                return
            }
            dyingSurfaceIdentity = UInt(bitPattern: dyingHandle)

            // Drop every strong reference to `dying` so it deallocates
            // before this block exits, scheduling its deferred cleanup
            // Task.
            dyingWindow.contentView = nil
        }

        // The deferred cleanup Task removes the surface-identity entry
        // synchronously before freeing the surface, so its disappearance
        // signals the Task has fully settled.
        waitUntil(timeout: 5.0) {
            TerminalSurfaceView.surfaceView(
                forSurfaceIdentity: dyingSurfaceIdentity
            ) == nil
        }

        var received = Data()
        survivor.onChildWrite = { received.append($0) }
        XCTAssertTrue(survivor.injectOutput(Data("\u{1b}[6n".utf8)))
        waitUntil(timeout: 5.0) {
            String(data: received, encoding: .utf8)?.contains("R") == true
        }
        let text = try XCTUnwrap(String(data: received, encoding: .utf8))
        XCTAssertTrue(
            text.contains("\u{1b}["),
            "expected onChildWrite to keep firing on the survivor after "
                + "sibling teardown, got \(text.debugDescription)"
        )
    }
}
