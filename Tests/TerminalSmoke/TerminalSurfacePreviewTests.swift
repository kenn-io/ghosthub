import AppKit
import CoreVideo
import GhosttyKit
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
            previousCaptureToken: nil
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

    func testSnapshotSkipsAnUnchangedIOSurfaceToken() async throws {
        let view = try makeSurface()
        view.layer?.contents = try makeIOSurface()
        let snapshotter = TerminalSurfaceSnapshotter()
        let captured = try await snapshotter.snapshot(
            of: view,
            outputSize: CGSize(width: 320, height: 200),
            previousCaptureToken: nil
        )
        let first = try XCTUnwrap(captured)

        let unchanged = try await snapshotter.snapshot(
            of: view,
            outputSize: CGSize(width: 320, height: 200),
            previousCaptureToken: first.captureToken
        )

        XCTAssertNil(unchanged)
    }

    func testSnapshotCapturesReplacementIOSurfaceWithRepeatedSeed() async throws {
        let view = try makeSurface()
        let firstSurface = try makeIOSurface()
        let replacementSurface = try makeIOSurface()
        XCTAssertNotEqual(
            IOSurfaceGetID(firstSurface),
            IOSurfaceGetID(replacementSurface)
        )
        XCTAssertEqual(
            IOSurfaceGetSeed(firstSurface),
            IOSurfaceGetSeed(replacementSurface)
        )
        view.layer?.contents = firstSurface
        let snapshotter = TerminalSurfaceSnapshotter()
        let firstCapture = try await snapshotter.snapshot(
            of: view,
            outputSize: CGSize(width: 320, height: 200),
            previousCaptureToken: nil
        )
        let first = try XCTUnwrap(firstCapture)

        view.layer?.contents = replacementSurface
        let replacement = try await snapshotter.snapshot(
            of: view,
            outputSize: CGSize(width: 320, height: 200),
            previousCaptureToken: first.captureToken
        )

        XCTAssertNotNil(replacement)
        XCTAssertEqual(
            replacement?.captureToken.surfaceID,
            IOSurfaceGetID(replacementSurface)
        )
    }

    func testSnapshotRejectsMissingContentsWithoutMutatingSurface() async throws {
        let view = try makeSurface()
        view.layer?.contents = nil
        let originalFrame = view.frame

        do {
            _ = try await TerminalSurfaceSnapshotter().snapshot(
                of: view,
                outputSize: CGSize(width: 320, height: 200),
                previousCaptureToken: nil
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
                previousCaptureToken: nil
            )
            XCTFail("Expected invalid output size failure")
        } catch {
            XCTAssertEqual(error as? TerminalSurfaceSnapshotError, .invalidOutputSize)
        }
    }

    func testParkedStateResignsFocusWithoutMutatingKeyViewLinks() throws {
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        let nextView = NSButton(title: "Next", target: nil, action: nil)
        view.nextKeyView = nextView
        nextView.nextKeyView = view
        XCTAssertTrue(window.firstResponder === view)

        view.setParkedForPreview(true)

        XCTAssertTrue(view.isParkedForPreview)
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertFalse(view.canBecomeKeyView)
        XCTAssertFalse(window.firstResponder === view)
        XCTAssertFalse(view.focused)
        XCTAssertTrue(view.nextKeyView === nextView)
        XCTAssertTrue(nextView.nextKeyView === view)

        view.setParkedForPreview(false)

        XCTAssertFalse(view.isParkedForPreview)
        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertTrue(view.canBecomeKeyView)
        XCTAssertFalse(window.firstResponder === view)
        XCTAssertTrue(view.nextKeyView === nextView)
        XCTAssertTrue(nextView.nextKeyView === view)
    }

    func testParkedStateSuppressesPointerTrackingAndDelivery() throws {
        let originalButtonSender = TerminalMouseEventHandler.mouseButtonSender
        let originalSender = TerminalMouseEventHandler.mousePositionSender
        let originalPressureSender = TerminalMouseEventHandler.mousePressureSender
        var buttonActions: [UInt32] = []
        var positions: [(Double, Double)] = []
        var pressureStages: [UInt32] = []
        TerminalMouseEventHandler.mouseButtonSender = {
            _, action, _, _ in
            buttonActions.append(action.rawValue)
            return true
        }
        TerminalMouseEventHandler.mousePositionSender = { _, x, y, _ in
            positions.append((x, y))
        }
        TerminalMouseEventHandler.mousePressureSender = { _, stage, _ in
            pressureStages.append(stage)
        }
        defer {
            TerminalMouseEventHandler.mouseButtonSender = originalButtonSender
            TerminalMouseEventHandler.mousePositionSender = originalSender
            TerminalMouseEventHandler.mousePressureSender = originalPressureSender
        }
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        view.updateTrackingAreas()
        XCTAssertFalse(view.trackingAreas.isEmpty)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        ))
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        view.mouseDown(with: mouseDown)

        view.setParkedForPreview(true)
        view.mouseMoved(with: event)

        XCTAssertTrue(view.trackingAreas.isEmpty)
        XCTAssertEqual(buttonActions, [
            GHOSTTY_MOUSE_PRESS.rawValue,
            GHOSTTY_MOUSE_RELEASE.rawValue,
        ])
        XCTAssertEqual(pressureStages, [0])
        XCTAssertEqual(positions.count, 1)
        XCTAssertEqual(positions.first?.0, -1)
        XCTAssertEqual(positions.first?.1, -1)

        view.setParkedForPreview(false)
        view.mouseMoved(with: event)

        XCTAssertFalse(view.trackingAreas.isEmpty)
        XCTAssertEqual(positions.count, 2)
    }

    func testParkingHostIsNoninteractiveAndPreservesSurfaceSize() throws {
        let originalOcclusionSetter = TerminalSurfaceView.occlusionSetter
        var occlusionStates: [Bool] = []
        TerminalSurfaceView.occlusionSetter = { surface, visible in
            occlusionStates.append(visible)
            originalOcclusionSetter(surface, visible)
        }
        defer {
            TerminalSurfaceView.occlusionSetter = originalOcclusionSetter
        }
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        try waitForIOSurface(in: view)
        let originalFrame = view.frame
        let originalBounds = view.bounds
        let originalSurfaceSize = try XCTUnwrap(view.surfaceSize)
        let root = NSView(frame: try XCTUnwrap(window.contentView).bounds)
        window.contentView = root
        let host = LivePreviewParkingHost(frame: root.bounds)
        root.addSubview(host)

        try host.park(view)

        XCTAssertTrue(host.contains(view))
        XCTAssertTrue(view.superview === host)
        XCTAssertEqual(view.frame, originalFrame)
        XCTAssertEqual(view.bounds, originalBounds)
        XCTAssertEqual(view.surfaceSize?.width_px, originalSurfaceSize.width_px)
        XCTAssertEqual(view.surfaceSize?.height_px, originalSurfaceSize.height_px)
        XCTAssertEqual(view.surfaceSize?.columns, originalSurfaceSize.columns)
        XCTAssertEqual(view.surfaceSize?.rows, originalSurfaceSize.rows)
        XCTAssertNil(host.hitTest(CGPoint(x: 10, y: 10)))
        XCTAssertEqual(host.accessibilityChildren()?.count, 0)
        XCTAssertFalse(host.isAccessibilityElement())
        XCTAssertTrue(view.layer?.contents is IOSurface)

        host.unpark(view)

        XCTAssertFalse(host.contains(view))
        XCTAssertNil(view.superview)
        XCTAssertFalse(view.isParkedForPreview)
        XCTAssertEqual(view.frame, originalFrame)
        XCTAssertEqual(view.bounds, originalBounds)
        XCTAssertEqual(occlusionStates.last, false)
    }

    func testParkingRejectsAStillMountedSurface() throws {
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        let host = LivePreviewParkingHost(frame: window.contentView?.bounds ?? .zero)

        XCTAssertThrowsError(try host.park(view)) { error in
            XCTAssertEqual(
                error as? LivePreviewParkingError,
                .surfaceStillMounted
            )
        }
        XCTAssertFalse(view.isParkedForPreview)
        XCTAssertFalse(host.contains(view))
    }

    private func makeSurface() throws -> TerminalSurfaceView {
        let runtime = retainedRuntime()
        let app = try XCTUnwrap(runtime.unsafeAppHandle)
        return TerminalSurfaceView(
            app: app,
            configuration: TerminalSurfaceConfiguration()
        )
    }

    private func makeIOSurface() throws -> IOSurface {
        try XCTUnwrap(IOSurfaceCreate([
            kIOSurfaceWidth: 32,
            kIOSurfaceHeight: 32,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 128,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ] as CFDictionary))
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
