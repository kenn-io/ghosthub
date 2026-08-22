import Foundation
import Testing
@testable import GhosthubTerminalSupport

@Suite("Surface pixel size")
struct SurfacePixelSizeTests {
    @Test("valid dimensions convert to libghostty pixels")
    func convertsValidDimensions() {
        #expect(
            SurfacePixelSize(CGSize(width: 1_200.75, height: 800.5))
                == SurfacePixelSize(CGSize(width: 1_200, height: 800))
        )
    }

    @Test(
        "invalid dimensions cannot reach libghostty",
        arguments: [
            CGSize(width: 0, height: 800),
            CGSize(width: 1_200, height: 0),
            CGSize(width: CGFloat.nan, height: 800),
            CGSize(width: 1_200, height: CGFloat.infinity),
            CGSize(
                width: SurfacePixelSize.maximumDimension + 1,
                height: 800
            ),
            CGSize(
                width: 1_200,
                height: SurfacePixelSize.maximumDimension + 1
            ),
        ]
    )
    func rejectsInvalidDimensions(_ size: CGSize) {
        #expect(SurfacePixelSize(size) == nil)
    }
}
