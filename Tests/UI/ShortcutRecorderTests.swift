import GhosthubTerminalSupport
import Testing
@testable import GhosthubUI

struct ShortcutRecorderTests {
    @Test("recording, cancel, clear, and restore preserve override intent")
    func recorderLifecycle() {
        var state = ShortcutRecorderState(
            action: .nextSibling,
            overrides: [:]
        )
        state.startRecording()
        #expect(state.isRecording)
        state.cancelRecording()
        #expect(state.displayedBinding == "⌃⇥")

        state.clear()
        #expect(state.overrides[.nextSibling] == .unbound)
        #expect(state.displayedBinding == "None")
        state.restoreDefault()
        #expect(state.overrides[.nextSibling] == nil)
        #expect(state.displayedBinding == "⌃⇥")
    }

    @Test("full draft collisions remain visible until replaced")
    func validatesCompleteDraft() throws {
        var state = ShortcutRecorderState(
            action: .nextSibling,
            overrides: [:]
        )
        state.startRecording()
        state.record(try ApplicationKeyBinding(parsing: "cmd+b"))
        #expect(state.isRecording)
        #expect(state.validationMessage == "Already used by Toggle Sidebar.")

        state.record(try ApplicationKeyBinding(parsing: "cmd+k"))
        #expect(!state.isRecording)
        #expect(state.validationMessage == nil)
        #expect(state.displayedBinding == "⌘K")
        #expect(state.accessibilityValue.contains("Restore Default"))
    }

    @Test("fixed shortcuts are rejected with their owner")
    func rejectsFixedShortcut() throws {
        var state = ShortcutRecorderState(
            action: .nextSibling,
            overrides: [:],
            isRecording: true
        )
        state.record(try ApplicationKeyBinding(parsing: "cmd+shift+]"))
        #expect(state.validationMessage == "Reserved for Next Tab.")
        #expect(state.isRecording)
    }
}
