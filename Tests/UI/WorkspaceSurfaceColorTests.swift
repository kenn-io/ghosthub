import AppKit
import Testing
@testable import GhosthubUI

@Suite("WorkspaceSurfaceColor opacity")
struct WorkspaceSurfaceColorTests {
    @Test("tinted variant carries the requested alpha")
    func tintAlpha() {
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let tinted = WorkspaceSurfaceColor.nsColor(opacity: 0.8)
            let resolved = tinted.usingColorSpace(.sRGB)
            #expect(resolved != nil)
            #expect(abs((resolved?.alphaComponent ?? 0) - 0.8) < 0.001)
        }
    }

    @Test("opacity 1 matches the canonical color")
    func fullOpacityMatchesCanonical() {
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let full = WorkspaceSurfaceColor.nsColor(opacity: 1.0)
                .usingColorSpace(.sRGB)
            let canonical = WorkspaceSurfaceColor.nsColor
                .usingColorSpace(.sRGB)
            #expect(full?.redComponent == canonical?.redComponent)
            #expect(full?.alphaComponent == 1.0)
        }
    }
}
