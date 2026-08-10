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
struct ShortcutRecorderWindowScope {
    let notificationObject: AnyObject
    let windowNumber: Int
    let isKeyWindow: () -> Bool

    init(window: NSWindow) {
        notificationObject = window
        windowNumber = window.windowNumber
        isKeyWindow = { [weak window] in
            window?.isKeyWindow == true
        }
    }

    init(
        notificationObject: AnyObject,
        windowNumber: Int,
        isKeyWindow: @escaping () -> Bool
    ) {
        self.notificationObject = notificationObject
        self.windowNumber = windowNumber
        self.isKeyWindow = isKeyWindow
    }
}

@MainActor
final class ShortcutRecorderMonitorCoordinator {
    typealias Handler = (NSEvent) -> NSEvent?
    typealias Install = (@escaping Handler) -> Any?
    typealias Remove = (Any) -> Void

    private let install: Install
    private let remove: Remove
    private let notificationCenter: NotificationCenter
    private var active: (
        owner: UUID,
        monitor: Any,
        resignObserver: NSObjectProtocol,
        onCancelled: () -> Void
    )?

    convenience init() {
        self.init(
            install: { handler in
                NSEvent.addLocalMonitorForEvents(
                    matching: .keyDown,
                    handler: handler
                )
            },
            remove: NSEvent.removeMonitor,
            notificationCenter: .default
        )
    }

    init(
        install: @escaping Install,
        remove: @escaping Remove,
        notificationCenter: NotificationCenter = .default
    ) {
        self.install = install
        self.remove = remove
        self.notificationCenter = notificationCenter
    }

    func start(
        owner: UUID,
        windowScope: ShortcutRecorderWindowScope,
        onCancelled: @escaping () -> Void,
        handler: @escaping Handler
    ) {
        stopActive(notifyCancelled: true)
        guard let monitor = install({ event in
            guard windowScope.isKeyWindow(),
                  event.windowNumber == windowScope.windowNumber
            else { return event }
            return handler(event)
        }) else { return }
        let resignObserver = notificationCenter.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: windowScope.notificationObject,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancel(owner: owner)
            }
        }
        active = (owner, monitor, resignObserver, onCancelled)
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
        stopActive(notifyCancelled: false)
    }

    private func cancel(owner: UUID) {
        guard active?.owner == owner else { return }
        stopActive(notifyCancelled: true)
    }

    private func stopActive(notifyCancelled: Bool) {
        guard let previous = active else { return }
        active = nil
        remove(previous.monitor)
        notificationCenter.removeObserver(previous.resignObserver)
        if notifyCancelled {
            previous.onCancelled()
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
        guard let window = NSApp.keyWindow else { return }
        monitorCoordinator.start(
            owner: monitorOwner,
            windowScope: ShortcutRecorderWindowScope(window: window),
            onCancelled: { update { $0.cancelRecording() } }
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
