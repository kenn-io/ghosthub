import Testing
@testable import GhosthubSettings
import GhosthubWorkspace

struct ConfigSectionEditorTests {

    // MARK: - renderTerminalAppearanceOverlay

    @Test func renderTerminalAppearanceOverlay_nilForConfig() {
        let prefs = TerminalAppearancePreferences(
            theme: .followConfig,
            usesCustomFont: false,
            fontFamily: "Berkeley Mono",
            fontSize: 13
        )

        let result = ConfigSectionEditor
            .renderTerminalAppearanceOverlay(for: prefs)

        #expect(result == nil)
    }

    @Test func renderTerminalAppearanceOverlay_includesCustomFont() {
        let prefs = TerminalAppearancePreferences(
            theme: .followConfig,
            usesCustomFont: true,
            fontFamily: "Monaco",
            fontSize: 14.5
        )

        let result = ConfigSectionEditor
            .renderTerminalAppearanceOverlay(for: prefs)

        #expect(result != nil)
        let text = result!
        #expect(text.contains("font-family = \"Monaco\""))
        #expect(text.contains("font-size = 14.5"))
        #expect(text.contains("# Ghosthub terminal appearance overlay"))
    }

    @Test func renderTerminalAppearanceOverlay_includesThemeColors() {
        let prefs = TerminalAppearancePreferences(
            theme: .pro,
            usesCustomFont: false,
            fontFamily: "Berkeley Mono",
            fontSize: 13
        )

        let result = ConfigSectionEditor
            .renderTerminalAppearanceOverlay(for: prefs)

        #expect(result != nil)
        let text = result!
        #expect(text.contains("background = "))
        #expect(text.contains("foreground = "))
        #expect(text.contains("cursor-color = "))
        #expect(text.contains("background-opacity = "))
    }

    @Test func renderTerminalAppearanceOverlay_themeAndFont() {
        let prefs = TerminalAppearancePreferences(
            theme: .homebrew,
            usesCustomFont: true,
            fontFamily: "JetBrains Mono",
            fontSize: 16
        )

        let result = ConfigSectionEditor
            .renderTerminalAppearanceOverlay(for: prefs)

        #expect(result != nil)
        let text = result!
        #expect(text.contains("background = "))
        #expect(
            text.contains("font-family = \"JetBrains Mono\"")
        )
        #expect(text.contains("font-size = 16"))
    }
}
