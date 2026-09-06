import AppKit
import Testing
@testable import GhosthubApp

@MainActor
@Suite("Update relaunch window placement")
struct UpdateRelaunchWindowPlacementTests {
    @Test("a frame on a disconnected display returns to an available screen")
    func restoresOffscreenFrame() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let window = NSWindow(
            contentRect: NSRect(
                x: screen.visibleFrame.minX + 50,
                y: screen.visibleFrame.minY + 50,
                width: 500,
                height: 300
            ),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        var state = WorkspaceWindowState.fresh()
        state.frame = WorkspaceWindowFrame(
            x: try #require(NSScreen.screens.map { $0.frame.maxX }.max()) + 2000,
            y: screen.visibleFrame.minY + 50,
            width: screen.visibleFrame.width + 200,
            height: 300
        )
        let placement = UpdateRelaunchWindowPlacement()
        placement.bind(window)
        placement.restore(state)

        #expect(screen.visibleFrame.contains(window.frame))
        #expect(!window.isVisible)
    }

    @Test("replayed windows recover their own frame regardless of binding order")
    func restoresMatchingFrames() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let firstFrame = NSRect(
            x: screen.visibleFrame.minX + 50,
            y: screen.visibleFrame.minY + 50,
            width: 500,
            height: 300
        )
        let secondFrame = firstFrame.offsetBy(dx: 70, dy: 80)
        let first = NSWindow(
            contentRect: firstFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let second = NSWindow(
            contentRect: secondFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            first.orderOut(nil)
            second.orderOut(nil)
        }
        first.setFrame(firstFrame, display: false)
        second.setFrame(secondFrame, display: false)
        let firstState = UpdateRelaunchWindowPlacement.capture(
            .fresh(), window: first
        )
        let secondState = UpdateRelaunchWindowPlacement.capture(
            .fresh(), window: second
        )
        first.setFrame(secondFrame, display: false)
        second.setFrame(firstFrame, display: false)

        let firstPlacement = UpdateRelaunchWindowPlacement()
        let secondPlacement = UpdateRelaunchWindowPlacement()
        secondPlacement.bind(second)
        secondPlacement.restore(secondState)
        firstPlacement.restore(firstState)
        firstPlacement.bind(first)

        #expect(first.frame == firstFrame)
        #expect(second.frame == secondFrame)
        #expect(!first.isVisible && !second.isVisible)

        // SwiftUI can report the same window again after the user moves it.
        first.setFrame(secondFrame, display: false)
        firstPlacement.bind(first)
        #expect(first.frame == secondFrame)

        // A late native identity corrects a provisional scene assignment.
        secondPlacement.restore(firstState)
        #expect(second.frame == firstFrame)
    }
}
