import AppKit
import Testing
@testable import GhosthubUI

@Suite("WorkspaceSurfaceColor opacity")
struct WorkspaceSurfaceColorTests {
    @Test(
        "tinted variant carries the requested alpha",
        arguments: [NSAppearance.Name.darkAqua, .aqua]
    )
    func tintAlpha(appearanceName: NSAppearance.Name) {
        NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
            let tinted = WorkspaceSurfaceColor.nsColor(opacity: 0.8)
            let resolved = tinted.usingColorSpace(.sRGB)
            #expect(resolved != nil)
            #expect(abs((resolved?.alphaComponent ?? 0) - 0.8) < 0.001)
        }
    }

    @Test("dynamic base color survives the alpha wrap")
    func dynamicResolutionSurvivesAlphaWrap() {
        var dark: NSColor?
        var light: NSColor?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            dark = WorkspaceSurfaceColor.nsColor(opacity: 0.8)
                .usingColorSpace(.sRGB)
        }
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            light = WorkspaceSurfaceColor.nsColor(opacity: 0.8)
                .usingColorSpace(.sRGB)
        }
        #expect(dark != nil)
        #expect(light != nil)
        #expect(dark?.redComponent != light?.redComponent)
    }

    @Test("opacity 1 matches the canonical color")
    func fullOpacityMatchesCanonical() {
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let full = WorkspaceSurfaceColor.nsColor(opacity: 1.0)
                .usingColorSpace(.sRGB)
            let canonical = WorkspaceSurfaceColor.nsColor
                .usingColorSpace(.sRGB)
            #expect(full?.redComponent == canonical?.redComponent)
            #expect(full?.greenComponent == canonical?.greenComponent)
            #expect(full?.blueComponent == canonical?.blueComponent)
            #expect(full?.alphaComponent == 1.0)
        }
    }

    @Test("out-of-range opacity clamps to 0...1")
    func opacityClamps() {
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let over = WorkspaceSurfaceColor.nsColor(opacity: 1.5)
                .usingColorSpace(.sRGB)
            let under = WorkspaceSurfaceColor.nsColor(opacity: -0.5)
                .usingColorSpace(.sRGB)
            #expect(over?.alphaComponent == 1.0)
            #expect(under?.alphaComponent == 0.0)
        }
    }
}
