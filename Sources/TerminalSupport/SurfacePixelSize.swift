import Foundation

package struct SurfacePixelSize: Equatable {
    /// libghostty derives its u16 grid dimensions by dividing screen pixels by
    /// a nonzero cell size. Bounding each pixel dimension to u16 keeps that
    /// conversion representable before crossing the C boundary.
    package static let maximumDimension = CGFloat(UInt16.max)

    package let width: UInt32
    package let height: UInt32

    package init?(_ size: CGSize) {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width >= 1,
              size.height >= 1,
              size.width <= Self.maximumDimension,
              size.height <= Self.maximumDimension
        else { return nil }

        width = UInt32(size.width)
        height = UInt32(size.height)
    }
}
