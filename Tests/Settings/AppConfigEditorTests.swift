import Testing
@testable import GhosthubSettings
import GhosthubWorkspace

struct AppConfigEditorTests {
    @Test("scalar replacement preserves comments and newline style")
    func replacesScalarSurgically() {
        let original = "[keyboard.shortcuts]\r\n"
            + "# navigation\r\n"
            + "next-sibling = \"ctrl+tab\" # keep this\r\n"
            + "future-action = \"future\"\r\n"

        let updated = AppConfigEditor.replacingString(
            sectionName: "keyboard.shortcuts",
            key: "next-sibling",
            value: "cmd+n",
            in: original
        )

        #expect(updated.contains(
            "next-sibling = \"cmd+n\" # keep this\r\n"
        ))
        #expect(updated.contains("future-action = \"future\"\r\n"))
        #expect(!updated.replacingOccurrences(of: "\r\n", with: "")
            .contains("\n"))
    }

    @Test("removing a scalar preserves its inline comment")
    func removesScalarAndPreservesComment() {
        let updated = AppConfigEditor.replacingString(
            sectionName: "keyboard.shortcuts",
            key: "next-sibling",
            value: nil,
            in: """
            [keyboard.shortcuts]
            next-sibling = "ctrl+tab" # chosen for navigation
            future-action = "future"
            """
        )

        #expect(!updated.contains("next-sibling"))
        #expect(updated.contains("# chosen for navigation"))
        #expect(updated.contains("future-action = \"future\""))
    }

    @Test("batch replacement adds one table and preserves unknown keys")
    func replacesScalarsInOnePass() {
        let updated = AppConfigEditor.replacingStrings(
            sectionName: "keyboard.shortcuts",
            values: [
                "next-sibling": "ctrl+shift+tab",
                "split-right": "none",
            ],
            in: "[general]\nappearance = \"system\"\n"
        )

        #expect(updated.components(
            separatedBy: "[keyboard.shortcuts]"
        ).count == 2)
        #expect(updated.contains(
            "next-sibling = \"ctrl+shift+tab\""
        ))
        #expect(updated.contains("split-right = \"none\""))
        #expect(updated.contains("appearance = \"system\""))
    }

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

    @Test("string array replacement recognizes a spaced section header")
    func recognizesSpacedSectionHeader() {
        let updated = AppConfigEditor.replacingStringArray(
            sectionName: "tmux",
            key: "hidden_session_patterns",
            values: ["forge-*"],
            in: """
            [ tmux ]
            hidden_session_patterns = ["old-*"]
            status = true
            """
        )

        #expect(!updated.contains("[tmux]"))
        #expect(updated.contains("[ tmux ]"))
        #expect(
            TOMLConfigParser.parseAppConfigStringArrayValue(
                sectionName: "tmux",
                key: "hidden_session_patterns",
                in: updated
            ) == ["forge-*"]
        )
    }

    @Test("string array replacement preserves CRLF configuration")
    func preservesCRLFConfiguration() {
        let updated = AppConfigEditor.replacingStringArray(
            sectionName: "tmux",
            key: "hidden_session_patterns",
            values: ["forge-*"],
            in: "[tmux]\r\nhidden_session_patterns = [\"old-*\"]\r\n"
                + "status = true\r\n"
        )

        #expect(updated.components(separatedBy: "[tmux]").count == 2)
        #expect(updated.replacingOccurrences(of: "\r\n", with: "")
            .contains("\n") == false)
        #expect(
            TOMLConfigParser.parseAppConfigStringArrayValue(
                sectionName: "tmux",
                key: "hidden_session_patterns",
                in: updated
            ) == ["forge-*"]
        )
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
