import GhosthubTerminalSupport
import Testing
@testable import GhosthubUI

@Suite("Application shortcut settings")
struct ApplicationShortcutsViewTests {
    @Test("catalog groups every configurable action")
    func groupsConfigurableActions() {
        let grouped = ApplicationShortcutSettingsGroup.allCases.flatMap {
            ApplicationShortcutReference.definitions(in: $0)
        }
        #expect(grouped.count == ApplicationShortcutCatalog.definitions.count)
        #expect(Set(grouped.map(\.action))
            == Set(ApplicationShortcutCatalog.definitions.map(\.action)))
    }

    @Test("native tab references expose fixed tab shortcuts")
    func nativeTabReferences() {
        let system = Dictionary(uniqueKeysWithValues:
            ApplicationShortcutReference.systemShortcuts.map {
                ($0.title, $0.binding.displayText)
            })
        #expect(system["Previous Tab"] == "⇧⌘[")
        #expect(system["Next Tab"] == "⇧⌘]")
        #expect(system["Select Tab 1"] == "⌘1")
        #expect(system["Select Tab 8"] == "⌘8")
        #expect(system["Select Last Tab"] == "⌘9")
        #expect(!system.values.contains("⌃⇥"))
    }
}
