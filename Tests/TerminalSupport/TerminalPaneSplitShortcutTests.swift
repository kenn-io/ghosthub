import Testing
@testable import GhosthubTerminalSupport

@Suite("Pane split shortcuts")
struct TerminalPaneSplitShortcutTests {
    @Test("application actions map to semantic directions")
    func splitDirections() throws {
        let cases: [(
            action: ApplicationShortcutAction,
            shortcut: TerminalPaneSplitShortcut
        )] = [
            (.splitRight, .right),
            (.splitDown, .down),
        ]

        for testCase in cases {
            let shortcut = try #require(
                TerminalPaneSplitShortcut(
                    applicationShortcutAction: testCase.action
                )
            )

            #expect(shortcut == testCase.shortcut)
        }
    }

    @Test("other application actions do not request a split")
    func unrelatedActions() {
        #expect(TerminalPaneSplitShortcut(
            applicationShortcutAction: .toggleSidebar
        ) == nil)
    }
}
