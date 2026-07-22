import GhosthubWorkspace
import SwiftUI

public struct CommandPaletteView: View {
    private let commands: [WorkspaceCommandItem]
    private let onSelect: (WorkspaceCommandAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isQueryFocused: Bool
    @State private var query = ""
    @State private var selectedIndex: Int?

    public init(
        commands: [WorkspaceCommandItem],
        onSelect: @escaping (WorkspaceCommandAction) -> Void
    ) {
        self.commands = commands
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Command Palette")
                .font(.title2.weight(.semibold))

            TextField(
                "Search commands, hosts, projects, or worktrees",
                text: $query
            )
            .textFieldStyle(.roundedBorder)
            .focused($isQueryFocused)
            .workspaceAccessibility(
                WorkspaceAccessibilityModel
                    .commandPaletteSearchDescriptor()
            )
            .onSubmit {
                guard let index = CommandPaletteSelection
                    .resolved(
                        selectedIndex: selectedIndex,
                        count: filteredCommands.count
                    )
                else { return }
                select(filteredCommands[index].action)
            }
            .onKeyPress(.downArrow) {
                selectedIndex = CommandPaletteSelection.moved(
                    from: selectedIndex,
                    direction: .down,
                    count: filteredCommands.count
                )
                return .handled
            }
            .onKeyPress(.upArrow) {
                selectedIndex = CommandPaletteSelection.moved(
                    from: selectedIndex,
                    direction: .up,
                    count: filteredCommands.count
                )
                return .handled
            }

            if filteredCommands.isEmpty {
                ContentUnavailableView(
                    "No Matching Commands",
                    systemImage: "magnifyingglass",
                    description: Text(
                        "Try a host name, worktree branch,"
                            + " or shortcut intent like"
                            + " 'find' or 'sidebar'."
                    )
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            } else {
                ScrollViewReader { proxy in
                    List(
                        Array(filteredCommands.enumerated()),
                        id: \.element.id
                    ) { offset, command in
                        Button {
                            select(command.action)
                        } label: {
                            WorkspaceCommandRow(command: command)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            selectedIndex == offset
                                ? Color.accentColor.opacity(0.2)
                                : Color.clear
                        )
                        .accessibilityElement(children: .ignore)
                        .workspaceAccessibility(
                            WorkspaceAccessibilityModel
                                .descriptor(for: command)
                        )
                        .id(command.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: selectedIndex) { _, newIndex in
                        if let newIndex,
                           newIndex < filteredCommands.count {
                            withAnimation {
                                proxy.scrollTo(
                                    filteredCommands[newIndex].id,
                                    anchor: .center
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            isQueryFocused = true
        }
        .onChange(of: query) {
            selectedIndex = nil
        }
    }

    private var filteredCommands: [WorkspaceCommandItem] {
        CommandPaletteModel.filteredCommands(commands, query: query)
    }

    private func select(_ action: WorkspaceCommandAction) {
        dismiss()
        onSelect(action)
    }
}

private struct WorkspaceCommandRow: View {
    let command: WorkspaceCommandItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(command.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(command.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let shortcut = command.shortcut {
                Text(shortcut.displayText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
