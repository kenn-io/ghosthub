import AppKit
import CoreGraphics
import Testing
@testable import GhosthubTerminal

/// The composite path moved onto the GPU (CoreImage over IOSurfaces) with the
/// always-live preview rework, so flattening coverage lives at the `opaqueFill`
/// seam the composite consumes; the live-surface smoke tests exercise the full
/// render.
@Suite("Terminal surface snapshot flattening")
struct TerminalSurfaceSnapshotFlatteningTests {
    @Test("translucent layer color becomes an opaque fill with the same components")
    func translucentColorBecomesOpaque() throws {
        let translucent = try #require(CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [0.2, 0.4, 0.6, 0.3]
        ))
        let fill = TerminalSurfaceSnapshotter.opaqueFill(from: translucent)
        #expect(fill.alpha == 1)
        let components = try #require(fill.components)
        #expect(components[0] == 0.2)
        #expect(components[1] == 0.4)
        #expect(components[2] == 0.6)
    }

    @Test("missing layer color falls back to opaque black")
    func missingColorFallsBackToOpaqueBlack() throws {
        let fill = TerminalSurfaceSnapshotter.opaqueFill(from: nil)
        #expect(fill.alpha == 1)
        let converted = try #require(
            fill.converted(
                to: CGColorSpaceCreateDeviceRGB(),
                intent: .defaultIntent,
                options: nil
            )
        )
        let components = try #require(converted.components)
        #expect(components[0] == 0)
        #expect(components[1] == 0)
        #expect(components[2] == 0)
    }
}
