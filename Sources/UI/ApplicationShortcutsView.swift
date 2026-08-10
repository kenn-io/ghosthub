import GhosthubTerminalSupport
import SwiftUI

enum ApplicationShortcutReference {
    static func definitions(
        in group: ApplicationShortcutSettingsGroup
    ) -> [ApplicationShortcutDefinition] {
        ApplicationShortcutCatalog.definitions.filter {
            $0.settingsGroup == group
        }
    }

    static let systemShortcuts = ApplicationShortcutCatalog.fixedShortcuts
}

struct ApplicationShortcutsView: View {
    @Binding var overrides:
        [ApplicationShortcutAction: ApplicationShortcutOverride]
    let configurationIssue: String?
    @State private var recorderMonitor =
        ShortcutRecorderMonitorCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let configurationIssue {
                Text(configurationIssue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            }
            ForEach(ApplicationShortcutSettingsGroup.allCases, id: \.self) {
                group in
                settingsSection(group.rawValue) {
                    ForEach(
                        ApplicationShortcutReference.definitions(in: group),
                        id: \.action
                    ) { definition in
                        HStack(alignment: .top) {
                            Text(definition.title)
                            Spacer()
                            ShortcutRecorder(
                                action: definition.action,
                                overrides: $overrides,
                                monitorCoordinator: recorderMonitor
                            )
                        }
                    }
                }
            }

            settingsSection("System Shortcuts") {
                ForEach(
                    ApplicationShortcutReference.systemShortcuts,
                    id: \.title
                ) { shortcut in
                    HStack {
                        Text(shortcut.title)
                        Spacer()
                        Text(shortcut.binding.displayText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            settingsSection("Tmux and Herdr Shortcuts") {
                Text(
                    "Pane, window, copy-mode, and session shortcuts remain configured and handled by tmux or Herdr."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
    }
}
