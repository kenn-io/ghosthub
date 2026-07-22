import AppKit
import GhosttyKit

@MainActor
protocol TerminalTextInputDelegate: AnyObject {
    var surfaceHandle: ghostty_surface_t? { get }
    var cellSize: NSSize { get }
    var frame: NSRect { get }
    var window: NSWindow? { get }
    var textInputObserver: ((String) -> Void)? { get }
    var commandObserver: ((Selector) -> Void)? { get }
    var lastPerformKeyEvent: TimeInterval? { get }
    /// See `TerminalSurfaceView.tmuxPaneInputSink`. When set, IME-committed
    /// text (outside an in-progress keyDown accumulation) is routed here
    /// instead of the local libghostty core.
    var tmuxPaneInputSink: ((Data) -> Void)? { get }
    func convert(_ rect: NSRect, to view: NSView?) -> NSRect
    func syncPreedit(clearIfNeeded: Bool)
}

@MainActor
final class TerminalTextInputHandler {
    weak var delegate: TerminalTextInputDelegate?
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?

    init(delegate: TerminalTextInputDelegate) {
        self.delegate = delegate
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0 ... (markedText.length - 1))
    }

    func selectedRange() -> NSRange {
        guard let surface = delegate?.surfaceHandle else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return NSRange()
        }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(
            location: Int(text.offset_start),
            length: Int(text.offset_len)
        )
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }

        if keyTextAccumulator == nil {
            delegate?.syncPreedit(clearIfNeeded: true)
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            delegate?.syncPreedit(clearIfNeeded: true)
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard let surface = delegate?.surfaceHandle else { return nil }
        guard range.length > 0 else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        guard let delegate,
              let surface = delegate.surfaceHandle
        else {
            return NSMakeRect(
                delegate?.frame.origin.x ?? 0,
                delegate?.frame.origin.y ?? 0,
                0,
                0
            )
        }

        var x: Double = 0
        var y: Double = 0
        var width: Double = delegate.cellSize.width
        var height: Double = delegate.cellSize.height
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let viewRect = NSMakeRect(
            x,
            delegate.frame.size.height - y,
            max(width, delegate.cellSize.width),
            max(height, delegate.cellSize.height)
        )

        let winRect = delegate.convert(viewRect, to: nil)
        guard let window = delegate.window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(
        _ string: Any,
        replacementRange: NSRange
    ) {
        guard let currentEvent = NSApp.currentEvent else { return }
        insertText(
            string,
            replacementRange: replacementRange,
            modifierFlags: currentEvent.modifierFlags
        )
    }

    func insertText(
        _ string: Any,
        replacementRange: NSRange,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let surface = delegate?.surfaceHandle else { return }

        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        unmarkText()

        delegate?.textInputObserver?(chars)

        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        // Committed IME text is routed to the pane like any other input;
        // in-progress preedit stays local (it's display-only and never
        // reaches this method until it commits). Ported from fantastty's
        // SurfaceView_AppKit.insertText, adapted from its `sendPaneInput`
        // call to ghosthub's `tmuxPaneInputSink` closure.
        if let sink = delegate?.tmuxPaneInputSink,
           let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: chars,
            eventCharacters: nil,
            modifierFlags: modifierFlags
           ) {
            sink(data)
            return
        }

        let len = chars.utf8CString.count
        guard len > 0 else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
    }

    func doCommand(by selector: Selector) {
        delegate?.commandObserver?(selector)
        if let lastPerformKeyEvent = delegate?.lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
    }
}
