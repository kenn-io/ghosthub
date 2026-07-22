import GhosthubWorkspace
import SwiftUI

extension View {
    func workspaceAccessibility(_ descriptor: WorkspaceAccessibilityDescriptor) -> some View {
        modifier(WorkspaceAccessibilityModifier(descriptor: descriptor))
    }
}

private struct WorkspaceAccessibilityModifier: ViewModifier {
    let descriptor: WorkspaceAccessibilityDescriptor

    func body(content: Content) -> some View {
        switch (descriptor.value, descriptor.hint) {
        case let (.some(value), .some(hint)):
            content
                .accessibilityLabel(Text(descriptor.label))
                .accessibilityValue(Text(value))
                .accessibilityHint(Text(hint))
        case let (.some(value), .none):
            content
                .accessibilityLabel(Text(descriptor.label))
                .accessibilityValue(Text(value))
        case let (.none, .some(hint)):
            content
                .accessibilityLabel(Text(descriptor.label))
                .accessibilityHint(Text(hint))
        case (.none, .none):
            content
                .accessibilityLabel(Text(descriptor.label))
        }
    }
}
