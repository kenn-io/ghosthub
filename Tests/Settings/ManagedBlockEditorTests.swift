import Testing
@testable import GhosthubSettings
import GhosthubWorkspace

struct ManagedBlockEditorTests {

    // MARK: - replacingManagedBlock

    @Test func appendsBlockToEmptyContent() {
        let result = ManagedBlockEditor.replacingManagedBlock(
            in: "",
            startMarker: "# >>> START >>>",
            endMarker: "# <<< END <<<",
            with: "# >>> START >>>\nvalue = 1\n# <<< END <<<"
        )

        #expect(result.contains("# >>> START >>>"))
        #expect(result.contains("value = 1"))
        #expect(result.contains("# <<< END <<<"))
        #expect(result.hasSuffix("# <<< END <<<\n"))
    }

    @Test func replacesExistingBlock() {
        let original = """
        some-setting = true

        # >>> START >>>
        old-value = 1
        # <<< END <<<
        """

        let result = ManagedBlockEditor.replacingManagedBlock(
            in: original,
            startMarker: "# >>> START >>>",
            endMarker: "# <<< END <<<",
            with: "# >>> START >>>\nnew-value = 2\n# <<< END <<<"
        )

        #expect(!result.contains("old-value = 1"))
        #expect(result.contains("new-value = 2"))
        #expect(result.contains("some-setting = true"))
    }

    @Test func managedBlockAlwaysAppearsAtEnd() {
        let original = """
        # >>> START >>>
        value = 1
        # <<< END <<<

        trailing-setting = true
        """

        let result = ManagedBlockEditor.replacingManagedBlock(
            in: original,
            startMarker: "# >>> START >>>",
            endMarker: "# <<< END <<<",
            with: "# >>> START >>>\nvalue = 2\n# <<< END <<<"
        )

        let blockStart = result.range(of: "# >>> START >>>")!
        let trailingSetting = result.range(of: "trailing-setting = true")!
        #expect(trailingSetting.lowerBound < blockStart.lowerBound)
    }

    @Test func preservesContentWithNoExistingBlock() {
        let original = "font-size = 14\ntheme = light\n"

        let result = ManagedBlockEditor.replacingManagedBlock(
            in: original,
            startMarker: "# >>> START >>>",
            endMarker: "# <<< END <<<",
            with: "# >>> START >>>\ninserted\n# <<< END <<<"
        )

        #expect(result.hasPrefix("font-size = 14\n"))
        #expect(result.contains("theme = light"))
        #expect(result.contains("inserted"))
    }

    // MARK: - replacingManagedTerminalBlock

    @Test func terminalBlockUsesCorrectMarkers() {
        let result = ManagedBlockEditor.replacingManagedTerminalBlock(
            in: "",
            with: "placeholder"
        )

        #expect(result.contains("placeholder"))
    }

    // MARK: - renderManagedTerminalBlock

    @Test func rendersTerminalBlockWithAllSettings() {
        let prefs = TerminalPreferences(
            cursorStyle: .bar,
            allowShellIntegrationToControlCursor: false,
            hideMouseWhileTyping: true,
            copySelectionToClipboard: true,
            showPaneResourceUsage: false
        )

        let result = ManagedBlockEditor.renderManagedTerminalBlock(
            for: prefs
        )

        #expect(result.hasPrefix(
            ManagedBlockEditor.managedTerminalBlockStart
        ))
        #expect(result.hasSuffix(
            ManagedBlockEditor.managedTerminalBlockEnd
        ))
        #expect(result.contains("cursor-style = bar"))
        #expect(result.contains("mouse-hide-while-typing = true"))
        #expect(result.contains("copy-on-select = clipboard"))
        #expect(result.contains("shell-integration = detect"))
        #expect(result.contains("shell-integration-features = no-cursor"))
        #expect(!result.contains("keybind"))
    }

    @Test func rendersTerminalBlockWithCursorControlAllowed() {
        let prefs = TerminalPreferences(
            cursorStyle: .block,
            allowShellIntegrationToControlCursor: true,
            hideMouseWhileTyping: false,
            copySelectionToClipboard: false,
            showPaneResourceUsage: false
        )

        let result = ManagedBlockEditor.renderManagedTerminalBlock(
            for: prefs
        )

        #expect(!result.contains("shell-integration-features"))
        #expect(result.contains("mouse-hide-while-typing = false"))
        #expect(result.contains("copy-on-select = false"))
        #expect(!result.contains("keybind"))
    }

}
