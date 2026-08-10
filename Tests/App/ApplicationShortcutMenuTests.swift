import GhosthubTerminalSupport
import Testing
@testable import GhosthubApp

struct ApplicationShortcutMenuTests {
    @Test("menu projections use the resolved registry")
    func menuProjection() throws {
        let shortcuts = try ApplicationShortcutCatalog.resolve(overrides: [
            .nextSibling: .binding(
                try ApplicationKeyBinding(parsing: "cmd+k")
            ),
            .splitRight: .unbound,
        ])

        let items = ApplicationShortcutMenuModel.items(
            [.previousSibling, .nextSibling, .splitRight],
            shortcuts: shortcuts
        )

        #expect(items[0].binding?.configValue == "ctrl+shift+tab")
        #expect(items[1].binding?.configValue == "cmd+k")
        #expect(items[2].binding == nil)
    }
}
