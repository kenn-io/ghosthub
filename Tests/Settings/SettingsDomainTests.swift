import Testing
@testable import GhosthubSettings

struct SettingsDomainTests {
    @Test("settings domains expose titles and subtitles")
    func settingsDomainsExposeTitlesAndSubtitles() {
        let expected: [(SettingsDomain, String, String)] = [
            (
                .appearance,
                "Appearance",
                "App chrome, built-in terminal themes,"
                    + " font overrides, and cursor styling."
            ),
            (
                .terminal,
                "Terminal",
                "Terminal interaction and ghostty.conf configuration."
            ),
            (
                .keyboard,
                "Keyboard",
                "Application and workspace navigation shortcuts."
            ),
            (
                .worktrees,
                "Worktrees",
                "Kwt workspace visibility and sidebar behavior."
            ),
            (
                .agents,
                "Agents",
                "Attention notifications for active agent sessions."
            ),
            (
                .privacy,
                "Privacy",
                "Control anonymous usage reporting."
            ),
            (
                .hosts,
                "Hosts",
                "Connect the machines and tmux sessions"
                    + " in your tailnet or SSH network."
            ),
        ]

        #expect(SettingsDomain.allCases == expected.map(\.0))
        for (domain, title, subtitle) in expected {
            #expect(domain.title == title)
            #expect(domain.subtitle == subtitle)
        }
    }
}
