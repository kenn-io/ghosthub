import Foundation
import GhosthubTerminalSupport
@testable import GhosthubSettings
import Testing

struct ShortcutPreferencesTests {
    @Test("known overrides and explicit unbinding resolve atomically")
    func loadsKnownOverrides() throws {
        let result = ShortcutPreferences.load(contents: """
        [keyboard.shortcuts]
        next-sibling = "cmd+k"
        split-right = "none"
        future-action = "ctrl+f12"
        """)

        guard case let .success(preferences) = result else {
            Issue.record("Expected valid shortcut preferences")
            return
        }
        #expect(preferences.overrides[.nextSibling]
            == .binding(try ApplicationKeyBinding(parsing: "cmd+k")))
        #expect(preferences.overrides[.splitRight] == .unbound)
        #expect(preferences.resolved[.splitRight] == nil)
    }

    @Test("Command-number overrides load without migration")
    func loadsNumberBindings() throws {
        let result = ShortcutPreferences.load(contents: """
        [keyboard.shortcuts]
        select-sibling-1 = "cmd+1"
        next-sibling = "cmd+k"
        """)

        guard case let .success(preferences) = result else {
            Issue.record("Expected valid shortcut preferences")
            return
        }
        let numberedBinding = try ApplicationKeyBinding(parsing: "cmd+1")
        let unrelatedBinding = try ApplicationKeyBinding(parsing: "cmd+k")
        #expect(preferences.overrides[.selectSibling1]
            == .binding(numberedBinding))
        #expect(preferences.overrides[.nextSibling]
            == .binding(unrelatedBinding))
        #expect(preferences.resolved[.selectSibling1] == numberedBinding)
        #expect(preferences.resolved[.nextSibling] == unrelatedBinding)
    }

    @Test("invalid known scalar reports the action")
    func rejectsInvalidScalar() {
        let result = ShortcutPreferences.load(contents: """
        [keyboard.shortcuts]
        next-sibling = 42
        """)

        guard case let .failure(issue) = result else {
            Issue.record("Expected a configuration issue")
            return
        }
        #expect(issue.action == .nextSibling)
        #expect(issue.message.contains("string"))
    }

    @Test("duplicate effective bindings reject the full set")
    func rejectsDuplicateBindings() {
        let result = ShortcutPreferences.load(contents: """
        [keyboard.shortcuts]
        next-sibling = "cmd+k"
        previous-sibling = "cmd+k"
        """)

        guard case let .failure(issue) = result else {
            Issue.record("Expected a configuration issue")
            return
        }
        #expect(issue.action == .previousSibling)
        #expect(issue.message.contains("Next Sibling"))
    }
}
