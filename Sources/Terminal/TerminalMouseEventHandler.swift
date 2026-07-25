import AppKit
import GhosttyKit

@MainActor
protocol TerminalMouseEventDelegate: AnyObject {
    var surfaceHandle: ghostty_surface_t? { get }
    var prevPressureStage: Int { get set }
    var frame: NSRect { get }
    func ensureFirstResponder()
    func convert(_ point: NSPoint, from view: NSView?) -> NSPoint
    func quickLook(with event: NSEvent)
}

@MainActor
struct TerminalMouseEventHandler {
    weak var delegate: TerminalMouseEventDelegate?

    init(delegate: TerminalMouseEventDelegate) {
        self.delegate = delegate
    }

    func handleMouseDown(_ event: NSEvent) {
        delegate?.ensureFirstResponder()
        guard let surface = delegate?.surfaceHandle else { return }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods
        )
    }

    func handleMouseUp(_ event: NSEvent) {
        delegate?.prevPressureStage = 0
        guard let surface = delegate?.surfaceHandle else { return }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods
        )
        ghostty_surface_mouse_pressure(surface, 0, 0)
    }

    func handleOtherMouseDown(_ event: NSEvent) {
        guard let surface = delegate?.surfaceHandle,
              event.buttonNumber == 2 else { return }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods
        )
    }

    func handleOtherMouseUp(_ event: NSEvent) {
        guard let surface = delegate?.surfaceHandle,
              event.buttonNumber == 2 else { return }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods
        )
    }

    func handleRightMouseDown(_ event: NSEvent) -> Bool {
        guard let surface = delegate?.surfaceHandle else { return false }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        return ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods
        )
    }

    func handleRightMouseUp(_ event: NSEvent) -> Bool {
        guard let surface = delegate?.surfaceHandle else { return false }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        return ghostty_surface_mouse_button(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods
        )
    }

    func handleMouseEntered(_ event: NSEvent) {
        guard let delegate,
              let surface = delegate.surfaceHandle else { return }
        let pos = delegate.convert(event.locationInWindow, from: nil)
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(
            surface, pos.x, delegate.frame.height - pos.y, mods
        )
    }

    func handleMouseExited(_ event: NSEvent) {
        guard let surface = delegate?.surfaceHandle else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, -1, -1, mods)
    }

    func handleMouseMoved(_ event: NSEvent) {
        guard let delegate,
              let surface = delegate.surfaceHandle else { return }
        let pos = delegate.convert(event.locationInWindow, from: nil)
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(
            surface, pos.x, delegate.frame.height - pos.y, mods
        )
    }

    func handleMouseDragged(_ event: NSEvent) {
        handleMouseMoved(event)
    }

    func handleRightMouseDragged(_ event: NSEvent) {
        handleMouseMoved(event)
    }

    func handleOtherMouseDragged(_ event: NSEvent) {
        handleMouseMoved(event)
    }

    func handleScrollWheel(_ event: NSEvent) {
        guard let surface = delegate?.surfaceHandle else { return }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas

        if precision {
            x *= 2
            y *= 2
        }

        let mods = TerminalInputHelpers.scrollMods(
            precision: precision,
            momentumPhase: event.momentumPhase
        )
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    func handlePressureChange(_ event: NSEvent) {
        guard let delegate,
              let surface = delegate.surfaceHandle else { return }
        ghostty_surface_mouse_pressure(
            surface, UInt32(event.stage), Double(event.pressure)
        )

        guard delegate.prevPressureStage < 2 else { return }
        delegate.prevPressureStage = event.stage
        guard event.stage == 2 else { return }
        guard UserDefaults.standard.bool(
            forKey: "com.apple.trackpad.forceClick"
        ) else { return }
        delegate.quickLook(with: event)
    }
}
