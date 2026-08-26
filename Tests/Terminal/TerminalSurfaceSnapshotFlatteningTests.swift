import AppKit
import CoreGraphics
import Testing
@testable import GhosthubTerminal

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

    @Test("thumbnail from a translucent surface over a translucent fill is fully opaque")
    func thumbnailPixelsAreOpaque() throws {
        let source = try #require(makeTranslucentImage(width: 8, height: 8))
        let thumbnail = try #require(TerminalSurfaceSnapshotter.makeThumbnail(
            source,
            outputSize: (width: 16, height: 12),
            backgroundColor: CGColor(red: 0, green: 0, blue: 1, alpha: 0.4)
        ))
        let pixels = try #require(thumbnail.dataProvider?.data as Data?)
        let bytesPerRow = thumbnail.bytesPerRow
        for row in 0 ..< thumbnail.height {
            for column in 0 ..< thumbnail.width {
                let alpha = pixels[row * bytesPerRow + column * 4 + 3]
                #expect(alpha == 255, "pixel (\(column), \(row)) is translucent")
            }
        }
    }

    private func makeTranslucentImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            ).union(.byteOrder32Little).rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
