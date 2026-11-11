import AppKit
import GhosthubSettings
import SwiftUI

/// One change made from the sidebar's options menu.
enum SidebarOptionChange: Equatable {
    case preferences(SidebarPreferences)
    case hideWorktreeSessions(Bool)
    case hideRootCheckout(Bool)
    case showHiddenWorktrees(Bool)
    case openSettings
}

/// The quiet menu beside the Workspaces title. It holds the sidebar's own
/// settings so people can change them without opening Settings.
struct SidebarOptionsMenu: View {
    let preferences: SidebarPreferences
    let hidesWorktreeSessions: Bool
    let hidesRootCheckout: Bool
    let showsHiddenWorktrees: Bool
    let onChange: (SidebarOptionChange) -> Void

    var body: some View {
        Menu {
            Section("Sort Sessions By") {
                Picker("Sort Sessions By", selection: preference(\.sessionSort)) {
                    ForEach(SidebarSessionSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Picker("Backend Label", selection: preference(\.backendLabelStyle)) {
                ForEach(SidebarBackendLabelStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Picker("Row Height", selection: preference(\.rowHeight)) {
                ForEach(SidebarRowHeight.allCases) { height in
                    Text(height.title).tag(height)
                }
            }
            Divider()
            Toggle("Hide Worktree Sessions", isOn: Binding(
                get: { hidesWorktreeSessions },
                set: { onChange(.hideWorktreeSessions($0)) }
            ))
            Toggle("Hide Root Checkout", isOn: Binding(
                get: { hidesRootCheckout },
                set: { onChange(.hideRootCheckout($0)) }
            ))
            Toggle("Show Hidden Worktrees", isOn: Binding(
                get: { showsHiddenWorktrees },
                set: { onChange(.showHiddenWorktrees($0)) }
            ))
            Divider()
            Button("Sidebar Settings…") { onChange(.openSettings) }
        } label: {
            // A sorted list ignores drag order, so mark when it applies.
            // The shape changes too, since a Graphite accent is grey.
            Image(nsImage: preferences.sessionSort == .manual
                ? Self.icon("line.3.horizontal.decrease", colors: [.secondaryLabelColor])
                : Self.icon(
                    "line.3.horizontal.decrease.circle.fill",
                    colors: [.white, .controlAccentColor]
                ))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sidebar options")
        .accessibilityLabel("Sidebar options")
        .accessibilityValue(sortDescription)
        .accessibilityIdentifier("sidebar-options")
    }

    /// AppKit draws a menu label as a template image in its own color, so
    /// bake the color into a non-template symbol.
    private static func icon(_ name: String, colors: [NSColor]) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .semibold
        ).applying(.init(paletteColors: colors))
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration) else { return NSImage() }
        image.isTemplate = false
        return image
    }

    private var sortDescription: String {
        preferences.sessionSort == .manual
            ? "Manual order"
            : "Sorted by \(preferences.sessionSort.title)"
    }

    private func preference<Value>(
        _ keyPath: WritableKeyPath<SidebarPreferences, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { value in
                var updated = preferences
                updated[keyPath: keyPath] = value
                onChange(.preferences(updated))
            }
        )
    }
}
