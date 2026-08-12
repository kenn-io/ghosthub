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
    static var mouseButtonSender: (
        ghostty_surface_t,
        ghostty_input_mouse_state_e,
        ghostty_input_mouse_button_e,
        ghostty_input_mods_e
    ) -> Bool = { surface, action, button, mods in
        ghostty_surface_mouse_button(surface, action, button, mods)
    }
    static var mousePositionSender: (
        ghostty_surface_t,
        Double,
        Double,
        ghostty_input_mods_e
    ) -> Void = { surface, x, y, mods in
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }
    static var mousePressureSender: (
        ghostty_surface_t,
        UInt32,
        Double
    ) -> Void = { surface, stage, pressure in
        ghostty_surface_mouse_pressure(surface, stage, pressure)
    }

    weak var delegate: TerminalMouseEventDelegate?
    private var pressedButtons: [ghostty_input_mouse_button_e] = []

    init(delegate: TerminalMouseEventDelegate) {
        self.delegate = delegate
    }

    mutating func handleMouseDown(_ event: NSEvent) {
        delegate?.ensureFirstResponder()
        guard let surface = delegate?.surfaceHandle else { return }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        _ = Self.mouseButtonSender(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods
        )
        recordPressed(GHOSTTY_MOUSE_LEFT)
    }

    mutating func handleMouseUp(_ event: NSEvent) {
        delegate?.prevPressureStage = 0
        guard let surface = delegate?.surfaceHandle else { return }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        _ = Self.mouseButtonSender(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods
        )
        recordReleased(GHOSTTY_MOUSE_LEFT)
        Self.mousePressureSender(surface, 0, 0)
    }

    mutating func handleOtherMouseDown(_ event: NSEvent) {
        guard let surface = delegate?.surfaceHandle,
              event.buttonNumber == 2 else { return }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        _ = Self.mouseButtonSender(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods
        )
        recordPressed(GHOSTTY_MOUSE_MIDDLE)
    }

    mutating func handleOtherMouseUp(_ event: NSEvent) {
        guard let surface = delegate?.surfaceHandle,
              event.buttonNumber == 2 else { return }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        _ = Self.mouseButtonSender(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods
        )
        recordReleased(GHOSTTY_MOUSE_MIDDLE)
    }

    mutating func handleRightMouseDown(_ event: NSEvent) -> Bool {
        guard let surface = delegate?.surfaceHandle else { return false }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        let handled = Self.mouseButtonSender(
            surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods
        )
        if handled {
            recordPressed(GHOSTTY_MOUSE_RIGHT)
        }
        return handled
    }

    mutating func handleRightMouseUp(_ event: NSEvent) -> Bool {
        guard let surface = delegate?.surfaceHandle else { return false }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        let handled = Self.mouseButtonSender(
            surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods
        )
        recordReleased(GHOSTTY_MOUSE_RIGHT)
        return handled
    }

    func handleMouseEntered(_ event: NSEvent) {
        guard let delegate,
              let surface = delegate.surfaceHandle else { return }
        let pos = delegate.convert(event.locationInWindow, from: nil)
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        Self.mousePositionSender(
            surface, pos.x, delegate.frame.height - pos.y, mods
        )
    }

    func handleMouseExited(_ event: NSEvent) {
        guard let surface = delegate?.surfaceHandle else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        Self.mousePositionSender(surface, -1, -1, mods)
    }

    func handleMouseMoved(_ event: NSEvent) {
        guard let delegate,
              let surface = delegate.surfaceHandle else { return }
        let pos = delegate.convert(event.locationInWindow, from: nil)
        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        Self.mousePositionSender(
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
        Self.mousePressureSender(
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

    mutating func resetPointerStateForParking() {
        guard let delegate,
              let surface = delegate.surfaceHandle else { return }
        for button in pressedButtons {
            _ = Self.mouseButtonSender(
                surface,
                GHOSTTY_MOUSE_RELEASE,
                button,
                GHOSTTY_MODS_NONE
            )
        }
        pressedButtons.removeAll()
        delegate.prevPressureStage = 0
        Self.mousePressureSender(surface, 0, 0)
        Self.mousePositionSender(surface, -1, -1, GHOSTTY_MODS_NONE)
    }

    private mutating func recordPressed(
        _ button: ghostty_input_mouse_button_e
    ) {
        guard !pressedButtons.contains(where: {
            $0.rawValue == button.rawValue
        }) else { return }
        pressedButtons.append(button)
    }

    private mutating func recordReleased(
        _ button: ghostty_input_mouse_button_e
    ) {
        pressedButtons.removeAll { $0.rawValue == button.rawValue }
    }
}
