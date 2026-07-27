import Testing
@testable import GhosthubUI

@Suite("Application shortcut reference")
struct ApplicationShortcutsViewTests {
    @Test("reference includes workspace and window shortcuts")
    func includesWorkspaceAndWindowShortcuts() {
        let shortcuts = Dictionary(uniqueKeysWithValues:
            ApplicationShortcutReference.shortcuts.map {
                ($0.title, $0.keys)
            })

        #expect(shortcuts["Select worktree 1–9"] == "⌘1–⌘9")
        #expect(shortcuts["Previous worktree"] == "⌥⌘↑")
        #expect(shortcuts["Next worktree"] == "⌥⌘↓")
        #expect(shortcuts["New worktree"] == "⇧⌘N")
        #expect(shortcuts["New window"] == "⌘N")
        #expect(shortcuts["New tab"] == "⌘T")
        #expect(shortcuts["Reload configuration"] == "⇧⌘,")
    }
}
