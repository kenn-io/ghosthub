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

@MainActor
final class ShortcutRecorderMonitorCoordinator {
    typealias Handler = (NSEvent) -> NSEvent?
    typealias Install = (@escaping Handler) -> Any?
    typealias Remove = (Any) -> Void

    private let install: Install
    private let remove: Remove
    private var active: (
        owner: UUID,
        monitor: Any,
        onSuperseded: () -> Void
    )?

    convenience init() {
        self.init(
            install: { handler in
                NSEvent.addLocalMonitorForEvents(
                    matching: .keyDown,
                    handler: handler
                )
            },
            remove: NSEvent.removeMonitor
        )
    }

    init(
        install: @escaping Install,
        remove: @escaping Remove
    ) {
        self.install = install
        self.remove = remove
    }

    func start(
        owner: UUID,
        onSuperseded: @escaping () -> Void,
        handler: @escaping Handler
    ) {
        stopActive(notifySuperseded: true)
        guard let monitor = install(handler) else { return }
        active = (owner, monitor, onSuperseded)
    }

    func recordingChanged(
        owner: UUID,
        from wasRecording: Bool,
        to isRecording: Bool
    ) {
        guard wasRecording, !isRecording else { return }
        stop(owner: owner)
    }

    func stop(owner: UUID) {
        guard active?.owner == owner else { return }
        stopActive(notifySuperseded: false)
    }

    private func stopActive(notifySuperseded: Bool) {
        guard let previous = active else { return }
        active = nil
        remove(previous.monitor)
        if notifySuperseded {
            previous.onSuperseded()
        }
    }
}

struct ShortcutRecorder: View {
    let action: ApplicationShortcutAction
    @Binding var overrides:
        [ApplicationShortcutAction: ApplicationShortcutOverride]
    let monitorCoordinator: ShortcutRecorderMonitorCoordinator
    @State private var isRecording = false
    @State private var validationMessage: String?
    @State private var monitorOwner = UUID()

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
        .onDisappear { monitorCoordinator.stop(owner: monitorOwner) }
    }

    private func beginRecording() {
        monitorCoordinator.start(
            owner: monitorOwner,
            onSuperseded: { update { $0.cancelRecording() } }
        ) { event in
            if event.keyCode == 53,
               event.modifierFlags.intersection(
                   .deviceIndependentFlagsMask
               ).isEmpty {
                update { $0.cancelRecording() }
                return nil
            }
            guard let binding = ApplicationKeyBinding(
                appKitModifierFlags: event.modifierFlags,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                keyCode: event.keyCode
            ) else { return nil }
            update { $0.record(binding) }
            return nil
        }
        update { $0.startRecording() }
    }

    private func update(
        _ change: (inout ShortcutRecorderState) -> Void
    ) {
        var updated = state
        let wasRecording = updated.isRecording
        change(&updated)
        overrides = updated.overrides
        isRecording = updated.isRecording
        validationMessage = updated.validationMessage
        monitorCoordinator.recordingChanged(
            owner: monitorOwner,
            from: wasRecording,
            to: updated.isRecording
        )
    }
}
