import AppKit
import IOSurface
import XCTest
@testable import GhosthubTerminal
@testable import GhosthubTerminalSupport

@MainActor
final class TerminalSurfacePreviewTests: XCTestCase {
    private static var retainedRuntime: LibghosttyRuntime?

    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessLibghosttyReady()
    }

    func testSnapshotCopiesAThumbnailWithoutMutatingSurface() async throws {
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        try waitForIOSurface(in: view)
        let originalSuperview = view.superview
        let originalFrame = view.frame
        let originalSurfaceSize = try XCTUnwrap(view.surfaceSize)
        let snapshotter = TerminalSurfaceSnapshotter()

        let captured = try await snapshotter.snapshot(
            of: view,
            outputSize: CGSize(width: 320, height: 200),
            previousSeed: nil
        )
        let snapshot = try XCTUnwrap(captured)

        XCTAssertEqual(snapshot.image.size, CGSize(width: 320, height: 200))
        let image = try XCTUnwrap(
            snapshot.image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        )
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 200)
        XCTAssertTrue(view.superview === originalSuperview)
        XCTAssertEqual(view.frame, originalFrame)
        XCTAssertEqual(view.surfaceSize?.width_px, originalSurfaceSize.width_px)
        XCTAssertEqual(view.surfaceSize?.height_px, originalSurfaceSize.height_px)
        XCTAssertNotNil(view.surfaceHandle)
    }

    func testSnapshotSkipsAnUnchangedIOSurfaceSeed() async throws {
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        try waitForIOSurface(in: view)
        let snapshotter = TerminalSurfaceSnapshotter()
        let captured = try await snapshotter.snapshot(
            of: view,
            outputSize: CGSize(width: 320, height: 200),
            previousSeed: nil
        )
        let first = try XCTUnwrap(captured)

        let unchanged = try await snapshotter.snapshot(
            of: view,
            outputSize: CGSize(width: 320, height: 200),
            previousSeed: first.ioSurfaceSeed
        )

        XCTAssertNil(unchanged)
    }

    func testSnapshotRejectsMissingContentsWithoutMutatingSurface() async throws {
        let view = try makeSurface()
        view.layer?.contents = nil
        let originalFrame = view.frame

        do {
            _ = try await TerminalSurfaceSnapshotter().snapshot(
                of: view,
                outputSize: CGSize(width: 320, height: 200),
                previousSeed: nil
            )
            XCTFail("Expected missing IOSurface failure")
        } catch {
            XCTAssertEqual(error as? TerminalSurfaceSnapshotError, .missingIOSurface)
        }
        XCTAssertEqual(view.frame, originalFrame)
        XCTAssertNil(view.superview)
    }

    func testSnapshotRejectsZeroOutputSize() async throws {
        let view = try makeSurface()

        do {
            _ = try await TerminalSurfaceSnapshotter().snapshot(
                of: view,
                outputSize: .zero,
                previousSeed: nil
            )
            XCTFail("Expected invalid output size failure")
        } catch {
            XCTAssertEqual(error as? TerminalSurfaceSnapshotError, .invalidOutputSize)
        }
    }

    private func makeSurface() throws -> TerminalSurfaceView {
        let runtime = retainedRuntime()
        let app = try XCTUnwrap(runtime.unsafeAppHandle)
        return TerminalSurfaceView(
            app: app,
            configuration: TerminalSurfaceConfiguration()
        )
    }

    private func retainedRuntime() -> LibghosttyRuntime {
        if Self.retainedRuntime == nil {
            let (pipeline, _) = makeIsolatedPipeline()
            try! FileManager.default.createDirectory(
                at: pipeline.paths.configDirectory,
                withIntermediateDirectories: true
            )
            try! "shell = /bin/zsh\n".write(
                to: pipeline.paths.globalConfigFile,
                atomically: true,
                encoding: .utf8
            )
            Self.retainedRuntime = LibghosttyRuntime(pipeline: pipeline)
        }
        return Self.retainedRuntime!
    }

    private func hostInWindow(_ view: TerminalSurfaceView) -> NSWindow {
        let size = CGSize(width: 960, height: 640)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.focusDidChange(true)
        view.sizeDidChange(size)
        return window
    }

    private func waitForIOSurface(in view: TerminalSurfaceView) throws {
        let deadline = Date().addingTimeInterval(5)
        while !(view.layer?.contents is IOSurface), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(view.layer?.contents is IOSurface)
    }
}
