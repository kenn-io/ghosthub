import AppKit
import CoreVideo
import GhosttyKit
import GhosthubTmux
import GhosthubTransport
import IOSurface
import os
import SwiftUI
import XCTest
@testable import GhosthubApp
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
            outputWidth: 320,
            previousCaptureToken: nil
        )
        let snapshot = try XCTUnwrap(captured)
        let expectedThumbnailSize = TerminalPreviewGeometry.thumbnailSize(
            sourceSize: CGSize(
                width: Int(originalSurfaceSize.width_px),
                height: Int(originalSurfaceSize.height_px)
            ),
            outputWidth: 320
        )

        XCTAssertEqual(snapshot.image.size, expectedThumbnailSize)
        let image = try XCTUnwrap(
            snapshot.image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        )
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, Int(expectedThumbnailSize.height))
        XCTAssertTrue(view.superview === originalSuperview)
        XCTAssertEqual(view.frame, originalFrame)
        XCTAssertEqual(view.surfaceSize?.width_px, originalSurfaceSize.width_px)
        XCTAssertEqual(view.surfaceSize?.height_px, originalSurfaceSize.height_px)
        XCTAssertNotNil(view.surfaceHandle)
    }

    func testSnapshotPreservesInRangeSourceAspectRatio() async throws {
        let view = try makeSurface()
        view.layer?.contents = try makeIOSurface(width: 400, height: 300)

        let captured = try await TerminalSurfaceSnapshotter().snapshot(
            of: view,
            outputWidth: 320,
            previousCaptureToken: nil
        )

        XCTAssertEqual(captured?.image.size, CGSize(width: 320, height: 240))
    }

    func testSnapshotSkipsAnUnchangedIOSurfaceToken() async throws {
        let view = try makeSurface()
        view.layer?.contents = try makeIOSurface()
        let stableToken = TerminalSurfaceCaptureToken(
            surfaceID: 1,
            seed: 1
        )
        let snapshotter = TerminalSurfaceSnapshotter { _ in stableToken }
        let captured = try await snapshotter.snapshot(
            of: view,
            outputWidth: 320,
            previousCaptureToken: nil
        )
        let first = try XCTUnwrap(captured)
        XCTAssertEqual(first.captureToken, stableToken)

        let unchanged = try await snapshotter.snapshot(
            of: view,
            outputWidth: 320,
            previousCaptureToken: first.captureToken
        )

        XCTAssertNil(unchanged)
    }

    func testSnapshotRetriesAnIOSurfaceGenerationChange() async throws {
        let view = try makeSurface()
        let ioSurface = try makeIOSurface()
        view.layer?.contents = ioSurface
        let surfaceID = IOSurfaceGetID(ioSurface)
        let tokenReads = OSAllocatedUnfairLock(initialState: 0)
        let snapshotter = TerminalSurfaceSnapshotter(captureToken: { _ in
            tokenReads.withLock { reads in
                defer { reads += 1 }
                return TerminalSurfaceCaptureToken(
                    surfaceID: surfaceID,
                    seed: reads == 0 ? 1 : 2
                )
            }
        })

        let captured = try await snapshotter.snapshot(
            of: view,
            outputWidth: 320,
            previousCaptureToken: nil
        )

        XCTAssertEqual(captured?.captureToken.seed, 2)
        XCTAssertEqual(tokenReads.withLock { $0 }, 4)
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
            outputWidth: 320,
            previousCaptureToken: nil
        )
        let first = try XCTUnwrap(firstCapture)

        view.layer?.contents = replacementSurface
        let replacement = try await snapshotter.snapshot(
            of: view,
            outputWidth: 320,
            previousCaptureToken: first.captureToken
        )

        XCTAssertNotNil(replacement)
        XCTAssertEqual(
            replacement?.captureToken.surfaceID,
            IOSurfaceGetID(replacementSurface)
        )
    }

    func testFreshSnapshotBypassesAnInFlightCoalescedRequest() async throws {
        let view = try makeSurface()
        let ioSurface = try makeIOSurface()
        view.layer?.contents = ioSurface
        let surfaceID = IOSurfaceGetID(ioSurface)
        let firstReadStarted = expectation(description: "first capture started")
        let freshReadStarted = expectation(description: "fresh capture started")
        let releaseFirstRead = DispatchSemaphore(value: 0)
        let tokenReads = OSAllocatedUnfairLock(initialState: 0)
        let snapshotter = TerminalSurfaceSnapshotter(captureToken: { _ in
            let read = tokenReads.withLock { reads in
                reads += 1
                return reads
            }
            if read == 1 {
                firstReadStarted.fulfill()
                releaseFirstRead.wait()
                return TerminalSurfaceCaptureToken(
                    surfaceID: surfaceID,
                    seed: 1
                )
            }
            if read == 2 {
                freshReadStarted.fulfill()
            }
            return TerminalSurfaceCaptureToken(
                surfaceID: surfaceID,
                seed: 2
            )
        })
        let first = Task {
            try await snapshotter.snapshot(
                of: view,
                outputWidth: 320,
                previousCaptureToken: nil
            )
        }
        await fulfillment(of: [firstReadStarted], timeout: 1)
        defer { first.cancel() }

        let fresh = Task {
            try await snapshotter.snapshot(
                of: view,
                outputWidth: 320,
                previousCaptureToken: nil,
                coalescesInFlight: false
            )
        }
        await fulfillment(of: [freshReadStarted], timeout: 1)
        releaseFirstRead.signal()
        let snapshot = try await fresh.value

        XCTAssertEqual(snapshot?.captureToken.seed, 2)
    }

    func testSnapshotRejectsMissingContentsWithoutMutatingSurface() async throws {
        let view = try makeSurface()
        view.layer?.contents = nil
        let originalFrame = view.frame

        do {
            _ = try await TerminalSurfaceSnapshotter().snapshot(
                of: view,
                outputWidth: 320,
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
                outputWidth: 0,
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

    func testParkingReleasesUnconsumedRightPressWithOriginalModifiers() throws {
        let originalButtonSender = TerminalMouseEventHandler.mouseButtonSender
        var actions: [(UInt32, UInt32, UInt32)] = []
        TerminalMouseEventHandler.mouseButtonSender = {
            _, action, button, modifiers in
            actions.append((action.rawValue, button.rawValue, modifiers.rawValue))
            return action.rawValue != GHOSTTY_MOUSE_PRESS.rawValue
        }
        defer {
            TerminalMouseEventHandler.mouseButtonSender = originalButtonSender
        }
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        let rightMouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [.shift],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1
        ))

        view.rightMouseDown(with: rightMouseDown)
        view.setParkedForPreview(true)

        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].0, GHOSTTY_MOUSE_PRESS.rawValue)
        XCTAssertEqual(actions[0].1, GHOSTTY_MOUSE_RIGHT.rawValue)
        XCTAssertEqual(actions[1].0, GHOSTTY_MOUSE_RELEASE.rawValue)
        XCTAssertEqual(actions[1].1, GHOSTTY_MOUSE_RIGHT.rawValue)
        XCTAssertEqual(actions[1].2, actions[0].2)
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

    func testPreviewRemovalUnparksAfterNativeSurfaceLookupIsRemoved() throws {
        let surface = try makeSurface()
        surface.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let root = NSView(frame: surface.frame)
        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let parkingHost = LivePreviewParkingHost(frame: root.bounds)
        root.addSubview(parkingHost)
        let key = TmuxPreviewKey(
            hostID: UUID(),
            name: "removed-native-surface",
            socketName: nil
        )
        var nativeSurface: TerminalSurfaceView? = surface
        let coordinator = TmuxSessionPreviewCoordinator(
            mode: .live,
            budget: LivePreviewBudget(limit: 1),
            capture: { _, _ in nil }
        )
        coordinator.installParkingHost(parkingHost)
        coordinator.register(.init(
            key: key,
            surface: { nativeSurface },
            handleID: { UUID() },
            generation: { nil },
            identity: {
                TmuxSessionIdentity(
                    serverPID: "101",
                    sessionID: "$1",
                    createdAt: "1000"
                )
            },
            connectionState: { .connected },
            isActive: { false },
            activate: {}
        ))
        coordinator.setExpanded(true, for: key)
        XCTAssertTrue(parkingHost.contains(surface))

        nativeSurface = nil
        coordinator.remove(key, reason: .close)

        XCTAssertFalse(parkingHost.contains(surface))
        XCTAssertNil(surface.superview)
        XCTAssertFalse(surface.isParkedForPreview)
    }

    func testPreviewActivationUnparksBeforeTheNormalTmuxMount() async throws {
        let surface = try makeSurface()
        surface.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let root = NSView(frame: surface.frame)
        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let parkingHost = LivePreviewParkingHost(frame: root.bounds)
        root.addSubview(parkingHost)
        let key = TmuxPreviewKey(
            hostID: UUID(),
            name: "previewed",
            socketName: nil
        )
        let handle = BorrowedTmuxSessionHandle(
            id: UUID(),
            hostID: key.hostID,
            name: key.name,
            surfaceID: UUID(),
            socketName: nil
        )
        var isActive = false
        var mount: NSHostingView<BorrowedTmuxSessionView>?
        let coordinator = TmuxSessionPreviewCoordinator(
            mode: .live,
            budget: LivePreviewBudget(limit: 1),
            capture: { presentation, _ in
                XCTAssertTrue(
                    presentation.surface()?.superview === parkingHost
                )
                return TerminalSurfaceSnapshot(
                    image: NSImage(size: CGSize(width: 32, height: 20)),
                    captureToken: TerminalSurfaceCaptureToken(
                        surfaceID: 1,
                        seed: 1
                    )
                )
            }
        )
        coordinator.installParkingHost(parkingHost)
        coordinator.register(.init(
            key: key,
            surface: { surface },
            handleID: { handle.id },
            generation: { nil },
            identity: {
                TmuxSessionIdentity(
                    serverPID: "101",
                    sessionID: "$1",
                    createdAt: "1000"
                )
            },
            connectionState: { .connected },
            isActive: { isActive },
            activate: {}
        ))
        coordinator.setExpanded(true, for: key)
        XCTAssertTrue(surface.superview === parkingHost)
        XCTAssertTrue(surface.isParkedForPreview)

        coordinator.prepareToActivate(key) {
            XCTAssertNil(surface.superview)
            XCTAssertFalse(surface.isParkedForPreview)
            isActive = true
            let presented = BorrowedTmuxSessionView(
                handle: handle,
                hostName: "This Mac",
                isRemoteHost: false,
                connectionState: .connected,
                surface: { surface },
                onCloseRequest: {},
                onRetryRequest: {},
                onHostSettingsRequest: {}
            )
            let hostingView = NSHostingView(rootView: presented)
            hostingView.frame = root.bounds
            root.addSubview(hostingView)
            mount = hostingView
        }
        await coordinator.waitForPendingWork()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertNotNil(mount)
        XCTAssertFalse(surface.superview === parkingHost)
        XCTAssertNotNil(surface.superview)
        XCTAssertFalse(surface.isParkedForPreview)
        XCTAssertFalse(surface.suppressAutoFocus)
        XCTAssertTrue(isActive)
    }

    func testParkingAdapterWaitsForAVisibleWorkspaceWindow() throws {
        let surface = try makeSurface()
        surface.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        let key = TmuxPreviewKey(
            hostID: UUID(),
            name: "park-after-mount",
            socketName: nil
        )
        let coordinator = TmuxSessionPreviewCoordinator(
            mode: .live,
            budget: LivePreviewBudget(limit: 1),
            capture: { _, _ in nil }
        )
        coordinator.register(.init(
            key: key,
            surface: { surface },
            handleID: { UUID() },
            generation: { nil },
            identity: {
                TmuxSessionIdentity(
                    serverPID: "101",
                    sessionID: "$1",
                    createdAt: "1000"
                )
            },
            connectionState: { .connected },
            isActive: { false },
            activate: {}
        ))
        coordinator.setExpanded(true, for: key)
        let container = TmuxSessionPreviewParkingView.ParkingContainer(
            previewCoordinator: coordinator
        )

        XCTAssertNil(surface.superview)

        let root = NSView(frame: surface.frame)
        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        container.frame = root.bounds
        root.addSubview(container)

        XCTAssertTrue(
            surface.superview === container.parkingHost
        )
        XCTAssertTrue(surface.isParkedForPreview)

        container.removeFromSuperview()

        XCTAssertNil(surface.superview)
        XCTAssertFalse(surface.isParkedForPreview)
    }

    private func makeSurface() throws -> TerminalSurfaceView {
        let runtime = retainedRuntime()
        let app = try XCTUnwrap(runtime.unsafeAppHandle)
        let view = TerminalSurfaceView(
            app: app,
            configuration: TerminalSurfaceConfiguration()
        )
        _ = try XCTUnwrap(
            view.surfaceHandle,
            view.error?.localizedDescription
                ?? "libghostty surface creation failed"
        )
        return view
    }

    private func makeIOSurface(
        width: Int = 32,
        height: Int = 32
    ) throws -> IOSurface {
        try XCTUnwrap(IOSurfaceCreate([
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: width * 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ] as CFDictionary))
    }

    private func retainedRuntime() -> LibghosttyRuntime {
        if Self.retainedRuntime == nil {
            let (pipeline, _) = makeIsolatedSurfacePipeline()
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
        let deadline = Date().addingTimeInterval(10)
        while !(view.layer?.contents is IOSurface), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        _ = try XCTUnwrap(
            view.layer?.contents as? IOSurface,
            "libghostty did not render an IOSurface before the deadline"
        )
    }
}
