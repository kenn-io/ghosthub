struct SurfaceResizeState: Equatable {
    struct Size: Equatable {
        let width: UInt32
        let height: UInt32
    }

    private(set) var lastPixelSize: Size?
    private(set) var pendingPixelSize: Size?

    mutating func needsResize(
        width: UInt32,
        height: UInt32
    ) -> Bool {
        let size = Size(width: width, height: height)
        return pendingPixelSize != size || lastPixelSize != size
    }

    mutating func setPending(
        width: UInt32,
        height: UInt32
    ) {
        pendingPixelSize = Size(width: width, height: height)
    }

    mutating func consumePending() -> Size? {
        defer { pendingPixelSize = nil }
        return pendingPixelSize
    }

    mutating func apply(
        width: UInt32,
        height: UInt32
    ) {
        pendingPixelSize = nil
        lastPixelSize = Size(width: width, height: height)
    }
}
