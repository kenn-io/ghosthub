import AppKit
import CoreImage
import IOSurface

public enum TerminalSurfaceSnapshotError: Error, Equatable {
    case invalidOutputSize
    case missingIOSurface
    case imageCopyFailed
}

public struct TerminalSurfaceCaptureToken: Hashable, Sendable {
    public let surfaceID: UInt32
    public let seed: UInt32

    public init(surfaceID: UInt32, seed: UInt32) {
        self.surfaceID = surfaceID
        self.seed = seed
    }
}

public struct TerminalSurfaceSnapshot: @unchecked Sendable {
    public let image: NSImage
    public let captureToken: TerminalSurfaceCaptureToken

    public init(image: NSImage, captureToken: TerminalSurfaceCaptureToken) {
        self.image = image
        self.captureToken = captureToken
    }
}

@MainActor
public final class TerminalSurfaceSnapshotter {
    private struct RequestKey: Hashable {
        let surface: ObjectIdentifier
        let width: Int
        let height: Int
        let previousCaptureToken: TerminalSurfaceCaptureToken?
    }

    private struct RenderSource: @unchecked Sendable {
        let ioSurface: IOSurface
        let backgroundColor: CGColor
        let pixelSize: (width: Int, height: Int)
        let previousCaptureToken: TerminalSurfaceCaptureToken?
    }

    private let ciContext: CIContext
    private var inFlight:
        [RequestKey: Task<TerminalSurfaceSnapshot?, Error>] = [:]

    public init() {
        ciContext = CIContext(options: [
            .cacheIntermediates: false,
        ])
    }

    public func snapshot(
        of surface: TerminalSurfaceView,
        outputSize: CGSize,
        previousCaptureToken: TerminalSurfaceCaptureToken?
    ) async throws -> TerminalSurfaceSnapshot? {
        let pixelSize = try Self.pixelSize(for: outputSize)
        let requestKey = RequestKey(
            surface: ObjectIdentifier(surface),
            width: pixelSize.width,
            height: pixelSize.height,
            previousCaptureToken: previousCaptureToken
        )
        if let pending = inFlight[requestKey] {
            return try await pending.value
        }

        guard let ioSurface = surface.layer?.contents as? IOSurface else {
            throw TerminalSurfaceSnapshotError.missingIOSurface
        }
        let source = RenderSource(
            ioSurface: ioSurface,
            backgroundColor: surface.layer?.backgroundColor
                ?? NSColor.black.cgColor,
            pixelSize: pixelSize,
            previousCaptureToken: previousCaptureToken
        )
        let ciContext = ciContext
        let task = Task.detached(priority: .utility) {
            try Self.makeSnapshot(
                source: source,
                ciContext: ciContext
            )
        }
        inFlight[requestKey] = task
        defer { inFlight.removeValue(forKey: requestKey) }
        return try await task.value
    }

    private static func pixelSize(
        for outputSize: CGSize
    ) throws -> (width: Int, height: Int) {
        guard outputSize.width.isFinite,
              outputSize.height.isFinite,
              outputSize.width > 0,
              outputSize.height > 0
        else {
            throw TerminalSurfaceSnapshotError.invalidOutputSize
        }
        let width = Int(outputSize.width.rounded())
        let height = Int(outputSize.height.rounded())
        guard width > 0, height > 0 else {
            throw TerminalSurfaceSnapshotError.invalidOutputSize
        }
        return (width, height)
    }

    private nonisolated static func makeSnapshot(
        source: RenderSource,
        ciContext: CIContext
    ) throws -> TerminalSurfaceSnapshot? {
        var lockedSeed: UInt32 = 0
        guard IOSurfaceLock(
            source.ioSurface,
            .readOnly,
            &lockedSeed
        ) == kIOReturnSuccess else {
            throw TerminalSurfaceSnapshotError.imageCopyFailed
        }
        defer {
            _ = IOSurfaceUnlock(source.ioSurface, .readOnly, nil)
        }
        let captureToken = TerminalSurfaceCaptureToken(
            surfaceID: IOSurfaceGetID(source.ioSurface),
            seed: lockedSeed
        )
        guard captureToken != source.previousCaptureToken else { return nil }

        let sourceImage = CIImage(ioSurface: source.ioSurface)
        guard !sourceImage.extent.isEmpty else {
            throw TerminalSurfaceSnapshotError.imageCopyFailed
        }
        let pixelSize = source.pixelSize
        let sourceExtent = sourceImage.extent
        let outputSize = CGSize(
            width: pixelSize.width,
            height: pixelSize.height
        )
        let scale = min(
            outputSize.width / sourceExtent.width,
            outputSize.height / sourceExtent.height
        )
        let scaledSize = CGSize(
            width: sourceExtent.width * scale,
            height: sourceExtent.height * scale
        )
        let transform = CGAffineTransform(
            translationX: (outputSize.width - scaledSize.width) / 2,
            y: (outputSize.height - scaledSize.height) / 2
        ).scaledBy(x: scale, y: scale)
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let background = CIImage(color: CIColor(cgColor: source.backgroundColor))
            .cropped(to: outputRect)
        let composed = sourceImage
            .transformed(by: transform)
            .composited(over: background)
            .cropped(to: outputRect)
        guard let image = ciContext.createCGImage(
            composed,
            from: outputRect,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            throw TerminalSurfaceSnapshotError.imageCopyFailed
        }
        return TerminalSurfaceSnapshot(
            image: NSImage(cgImage: image, size: outputSize),
            captureToken: captureToken
        )
    }
}
