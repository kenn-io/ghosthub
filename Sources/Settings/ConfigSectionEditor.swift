import Foundation
import GhosthubWorkspace

/// Pure-function helpers for rendering the terminal appearance
/// overlay file. Extracted from SettingsStore to keep file
/// rendering isolated and testable.
enum ConfigSectionEditor {

    // MARK: - Terminal Appearance Overlay

    /// Render the terminal appearance overlay file content.
    ///
    /// Tmux themes are intentionally absent from this libghostty overlay.
    /// They are applied to new tmux sessions, and optionally to shared
    /// sessions, at the tmux boundary. Returns `nil` when no custom font is
    /// configured, which signals the caller to delete the overlay file.
    static func renderTerminalAppearanceOverlay(
        for preferences: TerminalAppearancePreferences
    ) -> String? {
        var lines: [String] = []

        if preferences.usesCustomFont {
            lines.append(
                "# Ghosthub terminal appearance overlay"
            )
            lines.append(
                "# Generated automatically from Settings > Appearance"
            )
            let trimmedFamily = preferences.fontFamily
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedFamily.isEmpty {
                lines.append(
                    "font-family = \(TOMLConfigParser.renderTOMLString(trimmedFamily))"
                )
            }
            lines.append(
                "font-size = \(TOMLConfigParser.renderTOMLNumber(preferences.fontSize.roundedFontSize))"
            )
        }

        guard !lines.isEmpty else {
            return nil
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private extension Double {
    var roundedFontSize: Double {
        (self * 2.0).rounded() / 2.0
    }
}
