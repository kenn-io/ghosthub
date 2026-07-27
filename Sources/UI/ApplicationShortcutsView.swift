import SwiftUI

enum ApplicationShortcutReference {
    struct Shortcut: Identifiable, Equatable {
        let title: String
        let keys: String

        var id: String { title }
    }

    static let shortcuts = [
        Shortcut(title: "Settings", keys: "⌘,"),
        Shortcut(title: "Reload configuration", keys: "⇧⌘,"),
        Shortcut(title: "Command palette", keys: "⇧⌘P"),
        Shortcut(title: "Toggle sidebar", keys: "⌘B"),
        Shortcut(title: "Select worktree 1–9", keys: "⌘1–⌘9"),
        Shortcut(title: "Previous worktree", keys: "⌥⌘↑"),
        Shortcut(title: "Next worktree", keys: "⌥⌘↓"),
        Shortcut(title: "New worktree", keys: "⇧⌘N"),
        Shortcut(title: "New window", keys: "⌘N"),
        Shortcut(title: "New tab", keys: "⌘T"),
        Shortcut(title: "Close session presentation", keys: "⌘W"),
        Shortcut(title: "Close window", keys: "⇧⌘W"),
        Shortcut(title: "Application log", keys: "⌥⌘L"),
        Shortcut(title: "Quit Ghosthub", keys: "⌘Q"),
    ]
}

struct ApplicationShortcutsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("Application Shortcuts") {
                ForEach(ApplicationShortcutReference.shortcuts) { shortcut in
                    HStack {
                        Text(shortcut.title)
                        Spacer()
                        Text(shortcut.keys)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            settingsSection("Tmux Shortcuts") {
                Text(
                    "Pane, window, copy-mode, and session shortcuts are"
                        + " configured and handled by tmux. Ghosthub sends"
                        + " ordinary terminal input unchanged."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
