import AppKit
import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

// Row content shared by the sidebar and the Settings › Sidebar preview, so
// the preview always matches what the sidebar draws.

extension SidebarRowHeight {
    var points: CGFloat {
        switch self {
        case .regular: 28
        case .compact: 24
        }
    }
}

extension WorkspaceSidebarSessionBackend {
    /// Hues sit away from the agent attention colors (orange, purple,
    /// green) so a backend label never reads as an alert.
    var tint: Color {
        Color(nsColor: nsTint)
    }

    private var nsTint: NSColor {
        let (light, dark): (NSColor, NSColor) = switch self {
        case .tmux:
            (
                .init(srgbRed: 0.10, green: 0.50, blue: 0.48, alpha: 1),
                .init(srgbRed: 0.33, green: 0.77, blue: 0.74, alpha: 1)
            )
        case .zellij:
            (
                .init(srgbRed: 0.56, green: 0.44, blue: 0.04, alpha: 1),
                .init(srgbRed: 0.85, green: 0.71, blue: 0.32, alpha: 1)
            )
        case .herdrTerminal, .herdrTUI:
            (
                .init(srgbRed: 0.22, green: 0.37, blue: 0.78, alpha: 1),
                .init(srgbRed: 0.52, green: 0.64, blue: 0.95, alpha: 1)
            )
        case .rex:
            (
                .init(srgbRed: 0.36, green: 0.40, blue: 0.47, alpha: 1),
                .init(srgbRed: 0.66, green: 0.71, blue: 0.78, alpha: 1)
            )
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? dark : light
        }
    }
}

/// The trailing label that names a row's multiplexer.
struct SessionBackendLabel: View {
    let backend: WorkspaceSidebarSessionBackend
    let style: SidebarBackendLabelStyle
    var isSelected = false
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        switch style {
        case .chip:
            text
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    backend.tint.opacity(chipOpacity),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
        case .text:
            text
        case .dot:
            Circle()
                .fill(backend.tint)
                .frame(width: 6, height: 6)
        }
    }

    private var text: some View {
        Text(backend.label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(backend.tint)
            .lineLimit(1)
            .fixedSize()
    }

    private var chipOpacity: Double {
        if colorSchemeContrast == .increased {
            return 0.24
        }
        return isSelected ? 0.2 : 0.12
    }
}

/// One-line content of a session row: optional leading dot, name, stopped
/// marker, agent badge or activity dot, and the trailing backend label.
struct SidebarSessionRowContent: View {
    let title: String
    var detail: String?
    let backend: WorkspaceSidebarSessionBackend
    let labelStyle: SidebarBackendLabelStyle
    var agentAttention: AgentAttention?
    var showsRecentOutput = false
    var isStopped = false
    var isSelected = false
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    var body: some View {
        HStack(spacing: 6) {
            if labelStyle == .dot {
                SessionBackendLabel(backend: backend, style: .dot)
            }
            titleText
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if isStopped {
                Text("stopped")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if let agentAttention {
                AgentStateBadge(attention: agentAttention)
            } else if showsRecentOutput {
                Image(
                    systemName: differentiateWithoutColor
                        ? "waveform" : "circle.fill"
                )
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .help("Recent tmux output")
                .accessibilityHidden(true)
            }
            if labelStyle != .dot {
                SessionBackendLabel(
                    backend: backend,
                    style: labelStyle,
                    isSelected: isSelected
                )
                .accessibilityHidden(true)
            }
        }
    }

    /// Herdr terminals are named `space / tab`; the space part is dimmed.
    private var titleText: Text {
        let font = Font.system(size: 13)
        guard backend == .herdrTerminal,
              let split = title.range(of: " / ", options: .backwards)
        else {
            return Text(title).font(font)
                .foregroundStyle(isStopped ? .secondary : .primary)
        }
        return Text(title[..<split.upperBound]).font(font)
            .foregroundStyle(.secondary)
            + Text(title[split.upperBound...]).font(font)
    }
}

/// One-line content of a worktree row: name, then diff, sync, window, PR,
/// and checks status.
struct SidebarWorktreeRowContent: View {
    let title: String
    let status: WorktreeRowStatus
    var titleColor = Color.primary
    var isFlagged = false

    var body: some View {
        HStack(spacing: 6) {
            if isFlagged {
                Image(systemName: "flag.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(WorktreeFlagPresentation.flagColor)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            WorktreeStatusCluster(status: status)
            if let number = status.prNumber {
                HStack(spacing: 3) {
                    Text(status.isDraft ? "#\(number)·draft" : "#\(number)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let checks = status.checks {
                        ChecksGlyphView(glyph: checks)
                    }
                }
                .fixedSize()
                .help(status.prTitle.map { "PR #\(number): \($0)" } ?? "PR #\(number)")
            }
        }
    }
}

struct ChecksGlyphView: View {
    let glyph: ChecksGlyph

    var body: some View {
        switch glyph {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.green)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.red)
        case .pending:
            Image(systemName: "clock.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// The selected-row fill. Increased contrast adds an outline.
struct SidebarRowSelectionBackground: View {
    let isSelected: Bool
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                isSelected
                    ? Color.accentColor.opacity(
                        colorSchemeContrast == .increased ? 0.4 : 0.2
                    )
                    : Color.clear
            )
            .overlay {
                if isSelected, colorSchemeContrast == .increased {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.55), lineWidth: 1.5)
                }
            }
    }
}

enum WorkspaceSidebarHostMenuItem: Equatable {
    case newTmuxSession
    case newZellijSession
    case newHerdrSession
    case addProject
}

struct WorkspaceSidebarHostMenuEntry: Equatable {
    let item: WorkspaceSidebarHostMenuItem
    let title: String
    let isEnabled: Bool
    let help: String?
}

/// The host row's + menu. Unavailable backends stay listed but disabled,
/// with the reason as the item's tooltip.
enum WorkspaceSidebarHostMenuModel {
    static func entries(
        for host: HostSummary
    ) -> [[WorkspaceSidebarHostMenuEntry]] {
        var groups: [[WorkspaceSidebarHostMenuEntry]] = [[
            WorkspaceSidebarHostMenuEntry(
                item: .newTmuxSession,
                title: "New tmux Session…",
                isEnabled: true,
                help: nil
            ),
            WorkspaceSidebarHostMenuEntry(
                item: .newZellijSession,
                title: "New Zellij Session…",
                isEnabled: host.zellijAvailable,
                help: host.zellijAvailable
                    ? nil : "Zellij isn't available on \(host.sidebarTitle)."
            ),
            WorkspaceSidebarHostMenuEntry(
                item: .newHerdrSession,
                title: "New Herdr Session…",
                isEnabled: host.herdrAvailable,
                help: host.herdrAvailable
                    ? "Creates a Herdr TUI session."
                    : "Herdr isn't available on \(host.sidebarTitle)."
            ),
        ]]
        if host.canRegisterProjects {
            groups.append([
                WorkspaceSidebarHostMenuEntry(
                    item: .addProject,
                    title: "Add Project…",
                    isEnabled: true,
                    help: nil
                ),
            ])
        }
        return groups
    }
}
