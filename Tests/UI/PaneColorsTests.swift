import AppKit
import Testing
@testable import GhosthubUI

struct PaneColorsTests {
    @Test("workspace surface resolves to hex string")
    func workspaceSurfaceHexString() {
        let appearance = NSAppearance(named: .aqua)!
        let hex = WorkspaceSurfaceColor.hexString(
            for: appearance
        )

        #expect(hex == "#f8f8fa")
    }
}
