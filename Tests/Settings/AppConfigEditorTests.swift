import Testing
@testable import GhosthubSettings

struct AppConfigEditorTests {
    @Test("string array replacement preserves surrounding config")
    func replacesStringArray() {
        let original = """
        [general]
        default_shell = "/bin/zsh"

        [tmux]
        hidden_session_patterns = ["old-*"]
        status = true
        """

        let updated = AppConfigEditor.replacingStringArray(
            sectionName: "tmux",
            key: "hidden_session_patterns",
            values: ["forge-*", "quoted-\"name\""],
            in: original
        )

        #expect(updated.contains("default_shell = \"/bin/zsh\""))
        #expect(updated.contains("status = true"))
        #expect(
            updated.contains(
                #"hidden_session_patterns = ["forge-*", "quoted-\"name\""]"#
            )
        )
        #expect(!updated.contains("old-*"))
    }

    @Test("string array replacement adds a missing section")
    func addsMissingSection() {
        let updated = AppConfigEditor.replacingStringArray(
            sectionName: "tmux",
            key: "hidden_session_patterns",
            values: ["forge-*"],
            in: "[general]\nappearance = \"system\"\n"
        )

        #expect(updated.hasSuffix(
            "[tmux]\nhidden_session_patterns = [\"forge-*\"]\n"
        ))
    }

    @Test("string array replacement recognizes a commented section header")
    func recognizesCommentedSectionHeader() {
        let updated = AppConfigEditor.replacingStringArray(
            sectionName: "tmux",
            key: "hidden_session_patterns",
            values: ["forge-*"],
            in: "[tmux] # standalone sessions\nstatus = true\n"
        )

        #expect(updated.components(separatedBy: "[tmux]").count == 2)
        #expect(updated.contains(
            "hidden_session_patterns = [\"forge-*\"]"
        ))
    }

    @Test("string array replacement removes a multiline old value")
    func replacesMultilineArray() {
        let updated = AppConfigEditor.replacingStringArray(
            sectionName: "tmux",
            key: "hidden_session_patterns",
            values: ["forge-*", "team/*"],
            in: """
            [tmux]
            hidden_session_patterns = [
                "old-*",
                'old-literal',
            ]
            status = true
            """
        )

        #expect(!updated.contains("old-*"))
        #expect(!updated.contains("old-literal"))
        #expect(updated.contains(
            #"hidden_session_patterns = ["forge-*", "team/*"]"#
        ))
        #expect(!updated.contains(#"team\/*"#))
        #expect(updated.contains("status = true"))
    }

    @Test("multiline replacement preserves a first-line literal hash")
    func replacesMultilineArrayStartingWithLiteralHash() {
        let updated = AppConfigEditor.replacingStringArray(
            sectionName: "tmux",
            key: "hidden_session_patterns",
            values: ["forge-*"],
            in: """
            [tmux]
            hidden_session_patterns = ['team/#*',
                'old-*',
            ]
            status = true
            """
        )

        #expect(!updated.contains("team/#*"))
        #expect(!updated.contains("old-*"))
        #expect(updated.contains(
            #"hidden_session_patterns = ["forge-*"]"#
        ))
        #expect(updated.contains("status = true"))
    }
}
