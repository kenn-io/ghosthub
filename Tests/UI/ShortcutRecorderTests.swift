import AppKit
import Foundation
import GhosthubTerminalSupport
import Testing
@testable import GhosthubUI

@Suite("Shortcut recorder", .serialized)
@MainActor
struct ShortcutRecorderTests {
    @Test("starting a recorder replaces the active owner")
    func latestRecorderOwnsKeyboardInput() {
        var installed = 0
        var removed = 0
        var firstWasSuperseded = false
        let coordinator = ShortcutRecorderMonitorCoordinator(
            install: { _ in
                installed += 1
                return NSObject()
            },
            remove: { _ in removed += 1 }
        )
        let first = UUID()
        let second = UUID()

        coordinator.start(
            owner: first,
            onSuperseded: { firstWasSuperseded = true },
            handler: { $0 }
        )
        coordinator.start(
            owner: second,
            onSuperseded: {},
            handler: { $0 }
        )

        #expect(installed == 2)
        #expect(removed == 1)
        #expect(firstWasSuperseded)
        coordinator.stop(owner: first)
        #expect(removed == 1)
        coordinator.stop(owner: second)
        #expect(removed == 2)
    }

    @Test("clear and restore default remove the owned monitor")
    func endingRecordingStopsMonitoring() {
        var removed = 0
        let coordinator = ShortcutRecorderMonitorCoordinator(
            install: { _ in NSObject() },
            remove: { _ in removed += 1 }
        )
        let owner = UUID()
        var state = ShortcutRecorderState(
            action: .nextSibling,
            overrides: [:]
        )
        state.startRecording()
        coordinator.start(
            owner: owner,
            onSuperseded: {},
            handler: { $0 }
        )

        let wasRecording = state.isRecording
        state.clear()
        coordinator.recordingChanged(
            owner: owner,
            from: wasRecording,
            to: state.isRecording
        )

        #expect(removed == 1)

        state.startRecording()
        coordinator.start(
            owner: owner,
            onSuperseded: {},
            handler: { $0 }
        )
        let wasRecordingAgain = state.isRecording
        state.restoreDefault()
        coordinator.recordingChanged(
            owner: owner,
            from: wasRecordingAgain,
            to: state.isRecording
        )

        #expect(removed == 2)
    }

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

    @Test("bindings outside the config grammar remain unsaved")
    func rejectsUnpersistableBinding() {
        var state = ShortcutRecorderState(
            action: .nextSibling,
            overrides: [:],
            isRecording: true
        )
        state.record(ApplicationKeyBinding(
            modifiers: [.command],
            key: .character(" ")
        ))

        #expect(state.overrides[.nextSibling] == nil)
        #expect(state.validationMessage == "This key cannot be saved.")
        #expect(state.isRecording)
    }
}
