import AppKit
import GhosthubWorkspace
import SwiftUI

public extension AgentAttention {
    /// Amber for approval, purple for input, green for done and working.
    var tint: NSColor {
        switch self {
        case .approval: .systemOrange
        case .input: .systemPurple
        case .finished, .working: .systemGreen
        }
    }

    /// A speech bubble when the agent is waiting on the user, otherwise a dot.
    var symbolName: String {
        switch self {
        case .approval, .input: "bubble.left.fill"
        case .finished, .working: "circle.fill"
        }
    }
}

/// Trailing sidebar badge: a state icon and a one-word title. Waiting
/// bubbles breathe slowly, a working dot pulses, and a finished turn shows a
/// small steady dot.
struct AgentStateBadge: View {
    let attention: AgentAttention
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(attention.title)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color(nsColor: attention.tint))
        .fixedSize()
        .help(attention.label)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var icon: some View {
        let image = Image(systemName: attention.symbolName)
        switch attention {
        case .approval, .input:
            image
                .font(.system(size: 9))
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .working:
            image
                .font(.system(size: 6))
                .symbolEffect(.breathe, options: .repeating, isActive: !reduceMotion)
        case .finished:
            image
                .font(.system(size: 5))
                .opacity(0.7)
        }
    }
}
