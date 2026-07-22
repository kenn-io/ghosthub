import Foundation
import GhosthubWorkspace

/// Pure-function helpers for rendering the terminal appearance
/// overlay file. Extracted from SettingsStore to keep file
/// rendering isolated and testable.
enum ConfigSectionEditor {

    // MARK: - Terminal Appearance Overlay

    /// Render the terminal appearance overlay file content.
    ///
    /// Returns `nil` when no overlay is needed (followGhostty theme
    /// with no custom font), which signals the caller to delete the
    /// overlay file.
    static func renderTerminalAppearanceOverlay(
        for preferences: TerminalAppearancePreferences
    ) -> String? {
        var lines: [String] = []

        if let theme = preferences.theme.spec {
            lines.append(
                "# Ghosthub terminal appearance overlay"
            )
            lines.append(
                "# Generated automatically from Settings > Appearance"
            )
            lines.append(
                "background = \(theme.background.hexRGB)"
            )
            lines.append(
                "foreground = \(theme.foreground.hexRGB)"
            )
            lines.append(
                "cursor-color = \(theme.cursorColor.hexRGB)"
            )
            if let selection = theme.selection {
                lines.append(
                    "selection-background = \(selection.hexRGB)"
                )
            }
            lines.append(
                "background-opacity = \(TOMLConfigParser.renderTOMLNumber(theme.background.alpha))"
            )
        }

        if preferences.usesCustomFont {
            if lines.isEmpty {
                lines.append(
                    "# Ghosthub terminal appearance overlay"
                )
                lines.append(
                    "# Generated automatically from Settings > Appearance"
                )
            }
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
