import Foundation
import GhosthubWorkspace

/// Pure-function helpers for rendering and replacing managed config blocks.
/// Extracted from SettingsStore to keep block-editing logic isolated and
/// testable.
enum ManagedBlockEditor {

    // MARK: - Marker Constants

    static let managedTerminalBlockStart =
        "# >>> Ghosthub managed terminal settings >>>"
    static let managedTerminalBlockEnd =
        "# <<< Ghosthub managed terminal settings <<<"

    // MARK: - Rendering

    static func renderManagedTerminalBlock(
        for preferences: TerminalPreferences
    ) -> String {
        let copyOnSelect = preferences.copySelectionToClipboard
            ? "clipboard" : "false"
        let hideMouse = preferences.hideMouseWhileTyping
            ? "true" : "false"

        var lines = [
            managedTerminalBlockStart,
            "term = xterm-256color",
            "cursor-style = \(preferences.cursorStyle.rawValue)",
            "mouse-hide-while-typing = \(hideMouse)",
            "copy-on-select = \(copyOnSelect)",
            "shell-integration = detect",
        ]

        if !preferences.allowShellIntegrationToControlCursor {
            lines.append("shell-integration-features = no-cursor")
        }

        lines.append(managedTerminalBlockEnd)
        return lines.joined(separator: "\n")
    }

    // MARK: - Block Replacement

    static func replacingManagedTerminalBlock(
        in contents: String,
        with managedBlock: String
    ) -> String {
        replacingManagedBlock(
            in: contents,
            startMarker: managedTerminalBlockStart,
            endMarker: managedTerminalBlockEnd,
            with: managedBlock
        )
    }

    static func replacingManagedBlock(
        in contents: String,
        startMarker: String,
        endMarker: String,
        with managedBlock: String
    ) -> String {
        var updated = contents

        // Remove any existing managed block so the regenerated
        // block can be appended at EOF. This ensures managed
        // values are always last-wins regardless of where users
        // add manual overrides.
        if let startRange = updated.range(of: startMarker),
           let endRange = updated.range(of: endMarker),
           startRange.lowerBound <= endRange.lowerBound {
            var removeEnd = endRange.upperBound
            // Also consume trailing newline(s) left by the removed block.
            while removeEnd < updated.endIndex,
                  updated[removeEnd] == "\n" {
                removeEnd = updated.index(after: removeEnd)
            }
            updated.removeSubrange(startRange.lowerBound ..< removeEnd)
        }

        if !updated.hasSuffix("\n") {
            updated.append("\n")
        }

        updated.append("\n")
        updated.append(managedBlock)
        updated.append("\n")
        return updated
    }
}
