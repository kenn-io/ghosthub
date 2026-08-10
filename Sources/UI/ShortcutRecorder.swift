import AppKit
import GhosthubTerminalSupport
import SwiftUI

struct ShortcutRecorderState: Equatable {
    let action: ApplicationShortcutAction
    var overrides: [ApplicationShortcutAction: ApplicationShortcutOverride]
    var isRecording = false
    var validationMessage: String?

    var displayedBinding: String {
        switch overrides[action] {
        case let .binding(binding): binding.displayText
        case .unbound: "None"
        case nil: action.definition.defaultBinding?.displayText ?? "None"
        }
    }

    mutating func startRecording() {
        isRecording = true
        validationMessage = nil
    }

    mutating func cancelRecording() {
        isRecording = false
        validationMessage = nil
    }

    mutating func record(_ binding: ApplicationKeyBinding) {
        if let message = ApplicationShortcutCatalog.validationMessage(
            for: binding,
            action: action,
            overrides: overrides
        ) {
            validationMessage = message
            return
        }
        overrides[action] = .binding(binding)
        validationMessage = nil
        isRecording = false
    }

    mutating func clear() {
        overrides[action] = .unbound
        validationMessage = nil
        isRecording = false
    }

    mutating func restoreDefault() {
        overrides.removeValue(forKey: action)
        validationMessage = nil
        isRecording = false
    }

    var accessibilityValue: String {
        var parts = [action.definition.title, displayedBinding]
        if isRecording {
            parts.append("Recording")
        }
        parts.append("Clear")
        parts.append("Restore Default")
        if let validationMessage {
            parts.append(validationMessage)
        }
        return parts.joined(separator: ", ")
    }
}

struct ShortcutRecorder: View {
    let action: ApplicationShortcutAction
    @Binding var overrides:
        [ApplicationShortcutAction: ApplicationShortcutOverride]
    @State private var isRecording = false
    @State private var validationMessage: String?
    @State private var monitor: Any?

    private var state: ShortcutRecorderState {
        ShortcutRecorderState(
            action: action,
            overrides: overrides,
            isRecording: isRecording,
            validationMessage: validationMessage
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(isRecording ? "Type shortcut…" : state.displayedBinding) {
                    beginRecording()
                }
                .font(.system(size: 12, design: .monospaced))
                .accessibilityLabel("\(action.definition.title) shortcut")
                .accessibilityValue(state.accessibilityValue)

                Menu {
                    Button("Clear") {
                        update { $0.clear() }
                    }
                    Button("Restore Default") {
                        update { $0.restoreDefault() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { stopMonitoring() }
    }

    private func beginRecording() {
        update { $0.startRecording() }
        stopMonitoring()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            if event.keyCode == 53,
               event.modifierFlags.intersection(
                   .deviceIndependentFlagsMask
               ).isEmpty {
                update { $0.cancelRecording() }
                stopMonitoring()
                return nil
            }
            guard let binding = ApplicationKeyBinding(
                appKitModifierFlags: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                keyCode: event.keyCode
            ) else { return nil }
            update { $0.record(binding) }
            if validationMessage == nil {
                stopMonitoring()
            }
            return nil
        }
    }

    private func update(
        _ change: (inout ShortcutRecorderState) -> Void
    ) {
        var updated = state
        change(&updated)
        overrides = updated.overrides
        isRecording = updated.isRecording
        validationMessage = updated.validationMessage
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
