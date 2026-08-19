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

    func testSnapshotProducesGPUFrameWithoutMutatingSurface() async throws {
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        try waitForIOSurface(in: view)
        let originalSuperview = view.superview
        let originalFrame = view.frame
        let originalSurfaceSize = try XCTUnwrap(view.surfaceSize)
        let ioSurface = try XCTUnwrap(view.layer?.contents as? IOSurface)
        let snapshotter = TerminalSurfaceSnapshotter()

        let captured = try await snapshotter.snapshot(
            of: view,
            outputWidth: 320,
            previousCaptureToken: nil
        )
        let snapshot = try XCTUnwrap(captured)
        let previewFrame = try XCTUnwrap(snapshot.frame)

        XCTAssertEqual(snapshot.captureToken.surfaceID, IOSurfaceGetID(ioSurface))
        XCTAssertEqual(IOSurfaceGetWidth(previewFrame.ioSurface), 320)
        XCTAssertNotNil(
            IOSurfaceCopyValue(previewFrame.ioSurface, kIOSurfaceColorSpace)
        )
        XCTAssertEqual(
            previewFrame.pixelSize,
            TerminalPreviewGeometry.thumbnailSize(
                sourceSize: CGSize(
                    width: IOSurfaceGetWidth(ioSurface),
                    height: IOSurfaceGetHeight(ioSurface)
                ),
                outputWidth: 320
            )
        )
        XCTAssertFalse(previewFrame.ioSurface === ioSurface)
        XCTAssertTrue(view.superview === originalSuperview)
        XCTAssertEqual(view.frame, originalFrame)
        XCTAssertEqual(view.surfaceSize?.width_px, originalSurfaceSize.width_px)
        XCTAssertEqual(view.surfaceSize?.height_px, originalSurfaceSize.height_px)
        XCTAssertNotNil(view.surfaceHandle)
    }

    func testPreviewDisplaysGPUFramesThroughCoreAnimation() throws {
        let firstSurface = try makeIOSurface(width: 400, height: 300)
        let replacementSurface = try makeIOSurface(width: 800, height: 400)
        let firstFrame = TerminalSurfacePreviewFrame(
            ioSurface: firstSurface,
            pixelSize: CGSize(width: 400, height: 300)
        )
        let replacementFrame = TerminalSurfacePreviewFrame(
            ioSurface: replacementSurface,
            pixelSize: CGSize(width: 800, height: 400)
        )
        let preview = TerminalSurfacePreviewView(frame: NSRect(
            x: 0,
            y: 0,
            width: 320,
            height: 200
        ))

        preview.display(firstFrame)

        XCTAssertTrue(
            preview.layer?.contents as? IOSurface === firstSurface
        )
        XCTAssertEqual(preview.layer?.contentsGravity, .resize)
        XCTAssertTrue(preview.layer?.actions?["contents"] is NSNull)

        preview.display(replacementFrame)

        XCTAssertTrue(
            preview.layer?.contents as? IOSurface === replacementSurface
        )
    }

    func testSnapshotPreservesSourceAspectAcrossPreviewShapes() async throws {
        let view = try makeSurface()
        view.layer?.backgroundColor = NSColor.black.cgColor
        let snapshotter = TerminalSurfaceSnapshotter()

        for (sourceSize, expectedOutputSize) in [
            (CGSize(width: 400, height: 300), CGSize(width: 320, height: 240)),
            (CGSize(width: 800, height: 400), CGSize(width: 320, height: 160)),
        ] {
            let sourceSurface = try makeIOSurface(
                width: Int(sourceSize.width),
                height: Int(sourceSize.height)
            )
            XCTAssertEqual(IOSurfaceLock(sourceSurface, [], nil), kIOReturnSuccess)
            memset(
                try XCTUnwrap(IOSurfaceGetBaseAddress(sourceSurface)),
                0xFF,
                IOSurfaceGetAllocSize(sourceSurface)
            )
            XCTAssertEqual(IOSurfaceUnlock(sourceSurface, [], nil), kIOReturnSuccess)
            view.layer?.contents = sourceSurface
            let captured = try await snapshotter.snapshot(
                of: view,
                outputWidth: 320,
                previousCaptureToken: nil
            )
            let frame = try XCTUnwrap(captured?.frame)

            XCTAssertEqual(frame.pixelSize, expectedOutputSize)
            XCTAssertEqual(IOSurfaceGetWidth(frame.ioSurface), 320)
            XCTAssertEqual(
                IOSurfaceGetHeight(frame.ioSurface),
                Int(expectedOutputSize.height)
            )
            XCTAssertEqual(IOSurfaceLock(frame.ioSurface, [.readOnly], nil), kIOReturnSuccess)
            let pixels = try XCTUnwrap(IOSurfaceGetBaseAddress(frame.ioSurface))
                .assumingMemoryBound(to: UInt8.self)
            let rowBytes = IOSurfaceGetBytesPerRow(frame.ioSurface)
            let corner = pixels
            let center = pixels
                + Int(expectedOutputSize.height / 2) * rowBytes
                + 160 * 4
            XCTAssertGreaterThan(Int(corner[0]) + Int(corner[1]) + Int(corner[2]), 700)
            XCTAssertGreaterThan(Int(center[0]) + Int(center[1]) + Int(center[2]), 700)
            XCTAssertEqual(
                IOSurfaceUnlock(frame.ioSurface, [.readOnly], nil),
                kIOReturnSuccess
            )
        }
    }

    func testSnapshotUsesMetalCompatibleStrideForOddOutputWidth() async throws {
        let view = try makeSurface()
        let sourceSurface = try makeIOSurface(width: 400, height: 300)
        XCTAssertEqual(IOSurfaceLock(sourceSurface, [], nil), kIOReturnSuccess)
        memset(
            try XCTUnwrap(IOSurfaceGetBaseAddress(sourceSurface)),
            0xFF,
            IOSurfaceGetAllocSize(sourceSurface)
        )
        XCTAssertEqual(IOSurfaceUnlock(sourceSurface, [], nil), kIOReturnSuccess)
        view.layer?.contents = sourceSurface

        let captured = try await TerminalSurfaceSnapshotter().snapshot(
            of: view,
            outputWidth: 301,
            previousCaptureToken: nil
        )
        let frame = try XCTUnwrap(captured?.frame)
        XCTAssertEqual(frame.pixelSize, CGSize(width: 301, height: 226))
        XCTAssertEqual(IOSurfaceGetBytesPerRow(frame.ioSurface) % 16, 0)
        XCTAssertEqual(IOSurfaceLock(frame.ioSurface, [.readOnly], nil), kIOReturnSuccess)
        let center = try XCTUnwrap(IOSurfaceGetBaseAddress(frame.ioSurface))
            .assumingMemoryBound(to: UInt8.self)
            + 113 * IOSurfaceGetBytesPerRow(frame.ioSurface)
            + 150 * 4
        XCTAssertGreaterThan(Int(center[0]) + Int(center[1]) + Int(center[2]), 700)
        XCTAssertEqual(
            IOSurfaceUnlock(frame.ioSurface, [.readOnly], nil),
            kIOReturnSuccess
        )
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
            XCTAssertEqual(
                error as? TerminalSurfaceSnapshotError,
                .invalidOutputSize
            )
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
        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(positions.last?.0, -1)
        XCTAssertEqual(positions.last?.1, -1)

        view.setParkedForPreview(false)
        view.mouseMoved(with: event)

        XCTAssertFalse(view.trackingAreas.isEmpty)
        XCTAssertEqual(positions.count, 3)
    }

    func testCommandPointerEventsUseLatestDraggedLocation() throws {
        let originalButtonSender = TerminalMouseEventHandler.mouseButtonSender
        let originalPositionSender =
            TerminalMouseEventHandler.mousePositionSender
        var buttonModifiers: [UInt32] = []
        var positions: [(Double, Double, UInt32)] = []
        TerminalMouseEventHandler.mouseButtonSender = {
            _, _, button, mods in
            if button.rawValue == GHOSTTY_MOUSE_LEFT.rawValue {
                buttonModifiers.append(mods.rawValue)
            }
            return true
        }
        TerminalMouseEventHandler.mousePositionSender = {
            _, x, y, mods in
            positions.append((x, y, mods.rawValue))
        }
        defer {
            TerminalMouseEventHandler.mouseButtonSender = originalButtonSender
            TerminalMouseEventHandler.mousePositionSender =
                originalPositionSender
        }
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        let commandChanged = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0.9,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x37
        ))
        let mouseMoved = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 0,
            pressure: 0
        ))
        let dragMouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1
        ))
        let mouseDragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [],
            timestamp: 1.1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 4,
            clickCount: 1,
            pressure: 1
        ))
        let dragMouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [],
            timestamp: 1.2,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 5,
            clickCount: 1,
            pressure: 0
        ))
        let commandMouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [.command],
            timestamp: 1.3,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 6,
            clickCount: 1,
            pressure: 1
        ))
        let commandMouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [.command],
            timestamp: 1.4,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 7,
            clickCount: 1,
            pressure: 0
        ))

        view.mouseEntered(with: mouseMoved)
        view.mouseMoved(with: mouseMoved)
        view.mouseDown(with: dragMouseDown)
        view.mouseDragged(with: mouseDragged)
        view.mouseUp(with: dragMouseUp)
        positions.removeAll()
        buttonModifiers.removeAll()
        view.flagsChanged(with: commandChanged)
        view.mouseDown(with: commandMouseDown)
        view.mouseUp(with: commandMouseUp)

        XCTAssertEqual(positions.count, 2)
        for position in positions {
            XCTAssertEqual(position.0, 40)
            XCTAssertEqual(position.1, Double(view.frame.height) - 40)
        }
        XCTAssertEqual(buttonModifiers.count, 2)
        for modifier in positions.map(\.2) + buttonModifiers {
            XCTAssertNotEqual(
                modifier & GHOSTTY_MODS_SUPER.rawValue,
                0
            )
            XCTAssertNotEqual(
                modifier & GHOSTTY_MODS_SHIFT.rawValue,
                0
            )
        }
    }

    func testCommandMouseDownSendsPositionBeforePressWithoutMovement() throws {
        let originalButtonSender = TerminalMouseEventHandler.mouseButtonSender
        let originalPositionSender =
            TerminalMouseEventHandler.mousePositionSender
        var sequence: [String] = []
        var position: (Double, Double, UInt32)?
        TerminalMouseEventHandler.mouseButtonSender = {
            _, action, button, _ in
            if action.rawValue == GHOSTTY_MOUSE_PRESS.rawValue,
               button.rawValue == GHOSTTY_MOUSE_LEFT.rawValue {
                sequence.append("press")
            }
            return true
        }
        TerminalMouseEventHandler.mousePositionSender = {
            _, x, y, mods in
            sequence.append("position")
            position = (x, y, mods.rawValue)
        }
        defer {
            TerminalMouseEventHandler.mouseButtonSender = originalButtonSender
            TerminalMouseEventHandler.mousePositionSender =
                originalPositionSender
        }
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 30),
            modifierFlags: [.command],
            timestamp: 1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        view.mouseDown(with: mouseDown)

        let sentPosition = try XCTUnwrap(position)
        XCTAssertEqual(sequence, ["position", "press"])
        XCTAssertEqual(sentPosition.0, 20)
        XCTAssertEqual(sentPosition.1, Double(view.frame.height) - 30)
        XCTAssertNotEqual(
            sentPosition.2 & GHOSTTY_MODS_SUPER.rawValue,
            0
        )
        XCTAssertNotEqual(
            sentPosition.2 & GHOSTTY_MODS_SHIFT.rawValue,
            0
        )
    }

    func testLeftMouseGestureKeepsInitialCaptureRouteWhenCommandChanges() throws {
        let originalButtonSender = TerminalMouseEventHandler.mouseButtonSender
        let originalPositionSender =
            TerminalMouseEventHandler.mousePositionSender
        var buttonEvents: [(UInt32, UInt32)] = []
        var positionModifiers: [UInt32] = []
        TerminalMouseEventHandler.mouseButtonSender = {
            _, action, button, mods in
            if button.rawValue == GHOSTTY_MOUSE_LEFT.rawValue {
                buttonEvents.append((action.rawValue, mods.rawValue))
            }
            return true
        }
        TerminalMouseEventHandler.mousePositionSender = {
            _, _, _, mods in
            positionModifiers.append(mods.rawValue)
        }
        defer {
            TerminalMouseEventHandler.mouseButtonSender = originalButtonSender
            TerminalMouseEventHandler.mousePositionSender =
                originalPositionSender
        }
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        let mouseMoved = try XCTUnwrap(NSEvent.mouseEvent(
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
            timestamp: 1.1,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        let commandChanged = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 1.2,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x37
        ))
        let mouseDragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [.command],
            timestamp: 1.3,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1
        ))
        let mouseUp = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [.command],
            timestamp: 1.4,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 4,
            clickCount: 1,
            pressure: 0
        ))

        view.mouseMoved(with: mouseMoved)
        view.mouseDown(with: mouseDown)
        positionModifiers.removeAll()
        view.flagsChanged(with: commandChanged)
        view.mouseDragged(with: mouseDragged)
        view.mouseUp(with: mouseUp)

        XCTAssertEqual(buttonEvents.count, 2)
        XCTAssertEqual(buttonEvents[0].0, GHOSTTY_MOUSE_PRESS.rawValue)
        XCTAssertEqual(buttonEvents[1].0, GHOSTTY_MOUSE_RELEASE.rawValue)
        XCTAssertEqual(
            buttonEvents[0].1 & GHOSTTY_MODS_SHIFT.rawValue,
            0
        )
        XCTAssertEqual(
            buttonEvents[1].1 & GHOSTTY_MODS_SHIFT.rawValue,
            0
        )
        XCTAssertEqual(
            buttonEvents[1].1 & GHOSTTY_MODS_SUPER.rawValue,
            GHOSTTY_MODS_SUPER.rawValue
        )
        XCTAssertEqual(positionModifiers.count, 2)
        for modifiers in positionModifiers {
            XCTAssertEqual(modifiers & GHOSTTY_MODS_SHIFT.rawValue, 0)
            XCTAssertEqual(
                modifiers & GHOSTTY_MODS_SUPER.rawValue,
                GHOSTTY_MODS_SUPER.rawValue
            )
        }
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
        let originalSizeSetter = TerminalSurfaceView.sizeSetter
        let originalContentScaleSetter = TerminalSurfaceView.contentScaleSetter
        var occlusionStates: [Bool] = []
        var surfaceSizes: [(UInt32, UInt32)] = []
        var contentScales: [(Double, Double)] = []
        TerminalSurfaceView.occlusionSetter = { surface, visible in
            occlusionStates.append(visible)
            originalOcclusionSetter(surface, visible)
        }
        TerminalSurfaceView.sizeSetter = { surface, width, height in
            surfaceSizes.append((width, height))
            originalSizeSetter(surface, width, height)
        }
        TerminalSurfaceView.contentScaleSetter = { surface, xScale, yScale in
            contentScales.append((xScale, yScale))
            originalContentScaleSetter(surface, xScale, yScale)
        }
        defer {
            TerminalSurfaceView.occlusionSetter = originalOcclusionSetter
            TerminalSurfaceView.sizeSetter = originalSizeSetter
            TerminalSurfaceView.contentScaleSetter = originalContentScaleSetter
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
        surfaceSizes.removeAll()
        contentScales.removeAll()

        try host.park(view)
        view.viewDidChangeBackingProperties()

        XCTAssertTrue(host.contains(view))
        XCTAssertTrue(view.superview === host)
        XCTAssertEqual(view.frame, originalFrame)
        XCTAssertEqual(view.bounds, originalBounds)
        XCTAssertEqual(view.surfaceSize?.width_px, originalSurfaceSize.width_px)
        XCTAssertEqual(view.surfaceSize?.height_px, originalSurfaceSize.height_px)
        XCTAssertEqual(view.surfaceSize?.columns, originalSurfaceSize.columns)
        XCTAssertEqual(view.surfaceSize?.rows, originalSurfaceSize.rows)
        XCTAssertTrue(surfaceSizes.isEmpty)
        XCTAssertEqual(contentScales.count, 1)
        XCTAssertEqual(contentScales.first?.0, window.backingScaleFactor)
        XCTAssertEqual(contentScales.first?.1, window.backingScaleFactor)
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

    func testUnparkingOccludesSurfaceBeforeReparenting() throws {
        let originalOcclusionSetter = TerminalSurfaceView.occlusionSetter
        let view = try makeSurface()
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        let root = NSView(frame: try XCTUnwrap(window.contentView).bounds)
        window.contentView = root
        let host = LivePreviewParkingHost(frame: root.bounds)
        root.addSubview(host)
        try host.park(view)
        var occlusionEvents: [(visible: Bool, wasParked: Bool)] = []
        TerminalSurfaceView.occlusionSetter = { surface, visible in
            occlusionEvents.append((visible, view.superview === host))
            originalOcclusionSetter(surface, visible)
        }
        defer {
            TerminalSurfaceView.occlusionSetter = originalOcclusionSetter
        }

        host.unpark(view)

        XCTAssertEqual(occlusionEvents.first?.visible, false)
        XCTAssertEqual(occlusionEvents.first?.wasParked, true)
        XCTAssertNil(view.superview)
    }

    func testApplicationActivitySuspendsAndRestoresParkedSurfaceRendering()
        throws {
        let originalOcclusionSetter = TerminalSurfaceView.occlusionSetter
        var occlusionStates: [Bool] = []
        TerminalSurfaceView.occlusionSetter = { surface, visible in
            occlusionStates.append(visible)
            originalOcclusionSetter(surface, visible)
        }
        defer {
            TerminalSurfaceView.occlusionSetter = originalOcclusionSetter
        }

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
            name: "parked-activity",
            socketName: nil
        )
        let coordinator = TmuxSessionPreviewCoordinator(
            mode: .live,
            budget: LivePreviewBudget(limit: 1),
            capture: { _, _ in nil },
            isKeyWindow: { true }
        )
        defer { coordinator.shutdown() }
        coordinator.installParkingHost(parkingHost)
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
        XCTAssertTrue(parkingHost.contains(surface))
        occlusionStates.removeAll()

        coordinator.applicationDidResignActive()

        XCTAssertTrue(parkingHost.contains(surface))
        XCTAssertEqual(occlusionStates.last, false)
        let resignationEventCount = occlusionStates.count

        coordinator.applicationDidBecomeActive()

        XCTAssertTrue(parkingHost.contains(surface))
        XCTAssertGreaterThan(occlusionStates.count, resignationEventCount)
        XCTAssertEqual(
            occlusionStates.last,
            TerminalSurfaceView.resolvedOcclusionVisibility(for: window)
        )
    }

    func testParkingAppliesTheRequestedTmuxGridAndRestoresGeometry() throws {
        let view = try makeSurface()
        let originalFrame = view.frame
        XCTAssertTrue(view.sizeForPreviewGrid(columns: 100, rows: 30))
        XCTAssertTrue(view.sizeForPreviewGrid(columns: 100, rows: 30))
        let root = NSView(frame: originalFrame)
        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let host = LivePreviewParkingHost(frame: root.bounds)
        root.addSubview(host)

        try host.park(view)

        let previewSize = try XCTUnwrap(view.surfaceSize)
        XCTAssertEqual(Int(previewSize.columns), 100)
        XCTAssertEqual(Int(previewSize.rows), 30)
        XCTAssertEqual(view.frame, originalFrame)
        XCTAssertEqual(view.bounds.size, originalFrame.size)
        host.unpark(view)
        XCTAssertEqual(view.frame, originalFrame)
    }

    func testPromotionPreservesPreviewGridUntilInteractiveMount() throws {
        let view = try makeSurface()
        XCTAssertTrue(view.sizeForPreviewGrid(columns: 100, rows: 30))
        let previewSize = try XCTUnwrap(view.surfaceSize)

        view.clearPreviewGridSize()

        XCTAssertEqual(view.surfaceSize?.width_px, previewSize.width_px)
        XCTAssertEqual(view.surfaceSize?.height_px, previewSize.height_px)
        XCTAssertEqual(view.surfaceSize?.columns, previewSize.columns)
        XCTAssertEqual(view.surfaceSize?.rows, previewSize.rows)

        let interactiveBounds = NSRect(
            x: 0,
            y: 0,
            width: 960,
            height: 640
        )
        let root = NSView(frame: interactiveBounds)
        let window = NSWindow(
            contentRect: interactiveBounds,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        view.frame = .zero
        view.bounds = .zero
        root.addSubview(view)
        view.frame = interactiveBounds
        view.sizeDidChange(interactiveBounds.size)
        view.refreshGridSize()
        defer { window.orderOut(nil) }
        let interactiveSize = try XCTUnwrap(
            SurfacePixelSize(view.convertToBacking(view.bounds.size))
        )
        XCTAssertEqual(view.surfaceSize?.width_px, interactiveSize.width)
        XCTAssertEqual(view.surfaceSize?.height_px, interactiveSize.height)
    }

    func testUnparkingAnUnopenedZeroSizeSurfaceDoesNotPublishInvalidScale()
        throws {
        let view = try makeSurface()
        view.frame = .zero
        view.bounds = .zero
        let root = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: 640,
            height: 400
        ))
        let window = NSWindow(
            contentRect: root.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let host = LivePreviewParkingHost(frame: root.bounds)
        root.addSubview(host)

        try host.park(view)
        host.unpark(view)

        XCTAssertNil(view.superview)
        XCTAssertEqual(view.frame, .zero)
        XCTAssertEqual(view.bounds, .zero)
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
            capture: { _, _ in nil },
            isKeyWindow: { true }
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
        XCTAssertTrue(surface.sizeForPreviewGrid(columns: 116, rows: 94))
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
                    frame: TerminalSurfacePreviewFrame(
                        ioSurface: try self.makeIOSurface(
                            width: 32,
                            height: 20
                        ),
                        pixelSize: CGSize(width: 32, height: 20)
                    ),
                    captureToken: TerminalSurfaceCaptureToken(
                        surfaceID: 1,
                        seed: 1
                    )
                )
            },
            isKeyWindow: { true }
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
        surface.clearPreviewGridSize()

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
        let interactiveSize = try XCTUnwrap(
            SurfacePixelSize(surface.convertToBacking(surface.bounds.size))
        )
        XCTAssertEqual(surface.surfaceSize?.width_px, interactiveSize.width)
        XCTAssertEqual(surface.surfaceSize?.height_px, interactiveSize.height)
        try waitForIOSurface(in: surface, matching: interactiveSize)
        let interactiveIOSurface = try XCTUnwrap(
            surface.layer?.contents as? IOSurface
        )
        XCTAssertEqual(
            IOSurfaceGetWidth(interactiveIOSurface),
            Int(interactiveSize.width)
        )
        XCTAssertEqual(
            IOSurfaceGetHeight(interactiveIOSurface),
            Int(interactiveSize.height)
        )
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
            capture: { _, _ in nil },
            isKeyWindow: { true }
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
            let config = LibghosttyConfigPipeline.defaultGlobalConfigContents
                + "\nshell = /bin/zsh\n"
            try! config.write(
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

    private func waitForIOSurface(
        in view: TerminalSurfaceView,
        matching pixelSize: SurfacePixelSize? = nil
    ) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let ioSurface = view.layer?.contents as? IOSurface {
                guard let pixelSize else { return }
                if IOSurfaceGetWidth(ioSurface) == Int(pixelSize.width),
                   IOSurfaceGetHeight(ioSurface) == Int(pixelSize.height) {
                    return
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("libghostty did not render the expected IOSurface before the deadline")
    }
}
