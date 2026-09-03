import AppKit
import GhosthubTerminalSupport
import SwiftUI

struct TerminalFindOverlay: View {
    @ObservedObject var controller: TerminalFindController
    var restoreTerminalFocus: @MainActor @Sendable () -> Void

    var body: some View {
        if controller.isOpen {
            TerminalFindBar(
                controller: controller,
                restoreTerminalFocus: restoreTerminalFocus
            )
        }
    }
}

struct TerminalFindBar: View {
    enum FieldCommand: Equatable {
        case next
        case previous
        case close
    }

    @ObservedObject var controller: TerminalFindController
    var restoreTerminalFocus: @MainActor @Sendable () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TerminalFindSearchField(
                controller: controller,
                close: close
            )
            .frame(width: 220)
            .accessibilityIdentifier("terminal-find-field")
            if let status = controller.failureMessage
                ?? Self.statusText(for: controller.result) {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("terminal-find-status")
            }
            Button {
                controller.findNext()
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Find Next")
            .disabled(!controller.canNavigate)
            .accessibilityIdentifier("terminal-find-next")
            Button {
                controller.findPrevious()
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Find Previous")
            .disabled(!controller.canNavigate)
            .accessibilityIdentifier("terminal-find-previous")
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Hide Find Bar")
            .accessibilityIdentifier("terminal-find-close")
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding()
    }

    static func statusText(for result: TerminalFindResult) -> String? {
        switch result {
        case .idle:
            nil
        case .noMatch:
            "No matches"
        case let .match(total: .some(total), selected: .some(selected)):
            "\(selected) of \(total)"
        case let .match(total: .some(total), selected: nil):
            "\(total) \(total == 1 ? "match" : "matches")"
        case .match(total: nil, selected: _):
            nil
        }
    }

    static func fieldCommand(
        selector: Selector,
        shift: Bool
    ) -> FieldCommand? {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            shift ? .previous : .next
        case #selector(NSResponder.cancelOperation(_:)):
            .close
        default:
            nil
        }
    }

    private func close() {
        controller.close()
        DispatchQueue.main.async(execute: restoreTerminalFocus)
    }
}

private struct TerminalFindSearchField: NSViewRepresentable {
    @ObservedObject var controller: TerminalFindController
    var close: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, close: close)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Find"
        field.delegate = context.coordinator
        field.focusRingType = .none
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != controller.query {
            field.stringValue = controller.query
        }
        context.coordinator.controller = controller
        context.coordinator.close = close
        guard context.coordinator.selectionRevision
            != controller.fieldSelectionRevision
        else { return }
        context.coordinator.selectionRevision = controller.fieldSelectionRevision
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var controller: TerminalFindController
        var close: @MainActor @Sendable () -> Void
        var selectionRevision: UInt64 = 0

        init(
            controller: TerminalFindController,
            close: @escaping @MainActor @Sendable () -> Void
        ) {
            self.controller = controller
            self.close = close
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            controller.updateQuery(field.stringValue)
        }

        func control(
            _: NSControl,
            textView _: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            switch TerminalFindBar.fieldCommand(
                selector: selector,
                shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            ) {
            case .next:
                controller.findNext()
                return true
            case .previous:
                controller.findPrevious()
                return true
            case .close:
                close()
                return true
            case nil:
                return false
            }
        }
    }
}
