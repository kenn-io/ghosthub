import AppKit

public enum TerminalSurfaceSnapshotError: Error, Equatable {
    case invalidOutputSize
    case missingIOSurface
    case gpuUnavailable
    case invalidIOSurface
    case outputSurfaceCreationFailed
    case unstableIOSurface
}

public struct TerminalSurfaceCaptureToken: Hashable, Sendable {
    public let surfaceID: UInt32
    public let seed: UInt32

    public init(surfaceID: UInt32, seed: UInt32) {
        self.surfaceID = surfaceID
        self.seed = seed
    }
}

public final class TerminalSurfacePreviewFrame: @unchecked Sendable {}

public struct TerminalSurfaceSnapshot: @unchecked Sendable {
    public let frame: TerminalSurfacePreviewFrame
    public let captureToken: TerminalSurfaceCaptureToken

    public init(
        frame: TerminalSurfacePreviewFrame,
        captureToken: TerminalSurfaceCaptureToken
    ) {
        self.frame = frame
        self.captureToken = captureToken
    }
}

@MainActor
public final class TerminalSurfaceSnapshotter {
    public init() {}

    public func snapshot(
        of _: TerminalSurfaceView,
        outputWidth: CGFloat,
        previousCaptureToken _: TerminalSurfaceCaptureToken?,
        coalescesInFlight _: Bool = true
    ) async throws -> TerminalSurfaceSnapshot? {
        guard outputWidth.isFinite, outputWidth > 0 else {
            throw TerminalSurfaceSnapshotError.invalidOutputSize
        }
        throw TerminalSurfaceSnapshotError.gpuUnavailable
    }
}

@MainActor
public final class TerminalSurfacePreviewView: NSView {
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func display(_: TerminalSurfacePreviewFrame?) {}
}

public enum LivePreviewParkingError: Error, Equatable {
    case surfaceStillMounted
}

@MainActor
public final class LivePreviewParkingHost: NSView {
    private var parkedSurfaces: Set<ObjectIdentifier> = []

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func park(_ surface: TerminalSurfaceView) throws {
        parkedSurfaces.insert(ObjectIdentifier(surface))
    }

    public func unpark(_ surface: TerminalSurfaceView) {
        parkedSurfaces.remove(ObjectIdentifier(surface))
    }

    public func unparkAll() {
        parkedSurfaces.removeAll()
    }

    public func contains(_ surface: TerminalSurfaceView) -> Bool {
        parkedSurfaces.contains(ObjectIdentifier(surface))
    }
}
