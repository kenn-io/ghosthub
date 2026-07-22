import Foundation
import Testing
@testable import GhosthubTerminalSupport

@Suite("TmuxTerminalModeTracker")
struct TmuxTerminalModeTrackerTests {
    @Test("tracks split private mouse mode sequences")
    func tracksSplitMouseModes() {
        var tracker = TmuxTerminalModeTracker()

        tracker.consume(Data("ordinary output".utf8))
        #expect(!tracker.hasMouseModeState)

        tracker.consume(Data("\u{1b}[?1002;10".utf8))
        tracker.consume(Data("06h".utf8))

        #expect(tracker.hasMouseModeState)
        #expect(tracker.mouseModes.button)
        #expect(tracker.mouseModes.sgr)
        #expect(!tracker.mouseModes.standard)

        tracker.consume(Data("\u{1b}[?1002l".utf8))

        #expect(!tracker.mouseModes.button)
        #expect(tracker.mouseModes.sgr)
    }

    @Test("mouse mode families retain only the live Ghostty state")
    func mutuallyExclusiveMouseModes() {
        var tracker = TmuxTerminalModeTracker()

        tracker.consume(Data("\u{1b}[?1000h\u{1b}[?1002h".utf8))
        #expect(!tracker.mouseModes.standard)
        #expect(tracker.mouseModes.button)

        tracker.consume(Data("\u{1b}[?1002l".utf8))
        #expect(!tracker.mouseModes.standard)
        #expect(!tracker.mouseModes.button)
        #expect(!tracker.mouseModes.all)

        tracker.consume(Data("\u{1b}[?1005h\u{1b}[?1006h".utf8))
        #expect(!tracker.mouseModes.utf8)
        #expect(tracker.mouseModes.sgr)

        tracker.consume(Data("\u{1b}[?1006l".utf8))
        #expect(!tracker.mouseModes.utf8)
        #expect(!tracker.mouseModes.sgr)
    }

    @Test("soft and full resets preserve their distinct mode semantics")
    func resetsRetainedModes() {
        var tracker = TmuxTerminalModeTracker()
        tracker.consume(Data("\u{1b}[?1;1000;1006h".utf8))

        tracker.consume(Data("\u{1b}[!p".utf8))

        #expect(!tracker.applicationCursorKeys)
        #expect(tracker.mouseModes.standard)
        #expect(tracker.mouseModes.sgr)

        tracker.consume(Data("\u{1b}c".utf8))

        #expect(!tracker.applicationCursorKeys)
        #expect(tracker.mouseModes == TmuxTerminalMouseModes())
    }
}
