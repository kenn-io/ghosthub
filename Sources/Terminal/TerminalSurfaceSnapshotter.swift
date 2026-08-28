import AppKit
import CoreImage
import CoreVideo
import GhosthubTerminalSupport
import IOSurface
import Metal

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

/// A GPU-produced thumbnail that Core Animation can present without a CPU
/// pixel copy or a second texture upload.
public final class TerminalSurfacePreviewFrame: @unchecked Sendable {
    public let ioSurface: IOSurface
    public let pixelSize: CGSize

    public init(ioSurface: IOSurface, pixelSize: CGSize) {
        self.ioSurface = ioSurface
        self.pixelSize = pixelSize
    }
}

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
        let gpu: GPUCaptureContext
        let captureToken: @Sendable (IOSurface) -> TerminalSurfaceCaptureToken
    }

    private struct GPUCaptureContext: @unchecked Sendable {
        let context: CIContext
        let colorSpace: CGColorSpace
    }

    private struct RenderedSnapshot: @unchecked Sendable {
        let frame: TerminalSurfacePreviewFrame
        let captureToken: TerminalSurfaceCaptureToken
    }

    private let gpu: GPUCaptureContext?
    private let captureToken: @Sendable (IOSurface) -> TerminalSurfaceCaptureToken
    private var inFlight: [RequestKey: Task<RenderedSnapshot?, Error>] = [:]

    public convenience init() {
        self.init(captureToken: Self.captureToken)
    }

    init(
        captureToken: @escaping @Sendable (IOSurface) ->
            TerminalSurfaceCaptureToken
    ) {
        self.captureToken = captureToken
        if let device = MTLCreateSystemDefaultDevice(),
           let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) {
            gpu = GPUCaptureContext(
                context: CIContext(
                    mtlDevice: device,
                    options: [.cacheIntermediates: false]
                ),
                colorSpace: colorSpace
            )
        } else {
            gpu = nil
        }
    }

    public func snapshot(
        of surface: TerminalSurfaceView,
        outputWidth: CGFloat,
        previousCaptureToken: TerminalSurfaceCaptureToken?,
        coalescesInFlight: Bool = true
    ) async throws -> TerminalSurfaceSnapshot? {
        guard outputWidth.isFinite, outputWidth > 0 else {
            throw TerminalSurfaceSnapshotError.invalidOutputSize
        }
        guard let ioSurface = surface.layer?.contents as? IOSurface else {
            throw TerminalSurfaceSnapshotError.missingIOSurface
        }
        let thumbnailSize = TerminalPreviewGeometry.thumbnailSize(
            sourceSize: CGSize(
                width: IOSurfaceGetWidth(ioSurface),
                height: IOSurfaceGetHeight(ioSurface)
            ),
            outputWidth: outputWidth
        )
        let pixelSize = (
            width: Int(thumbnailSize.width),
            height: Int(thumbnailSize.height)
        )
        let requestKey = RequestKey(
            surface: ObjectIdentifier(surface),
            width: pixelSize.width,
            height: pixelSize.height,
            previousCaptureToken: previousCaptureToken
        )
        if coalescesInFlight, let pending = inFlight[requestKey] {
            guard let rendered = try await pending.value else { return nil }
            return Self.snapshot(from: rendered)
        }

        guard let gpu else {
            throw TerminalSurfaceSnapshotError.gpuUnavailable
        }
        let source = RenderSource(
            ioSurface: ioSurface,
            backgroundColor: surface.layer?.backgroundColor
                ?? NSColor.black.cgColor,
            pixelSize: pixelSize,
            previousCaptureToken: previousCaptureToken,
            gpu: gpu,
            captureToken: captureToken
        )
        let task = Task.detached(priority: .utility) {
            try Self.makeSnapshot(source: source)
        }
        if coalescesInFlight {
            inFlight[requestKey] = task
        }
        defer {
            if coalescesInFlight {
                inFlight.removeValue(forKey: requestKey)
            }
        }
        guard let rendered = try await task.value else { return nil }
        return Self.snapshot(from: rendered)
    }

    private static func snapshot(
        from rendered: RenderedSnapshot
    ) -> TerminalSurfaceSnapshot {
        TerminalSurfaceSnapshot(
            frame: rendered.frame,
            captureToken: rendered.captureToken
        )
    }

    private nonisolated static func makeSnapshot(
        source: RenderSource
    ) throws -> RenderedSnapshot? {
        guard IOSurfaceGetPixelFormat(source.ioSurface)
            == kCVPixelFormatType_32BGRA
        else {
            throw TerminalSurfaceSnapshotError.invalidIOSurface
        }
        let sourceWidth = IOSurfaceGetWidth(source.ioSurface)
        let sourceHeight = IOSurfaceGetHeight(source.ioSurface)
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw TerminalSurfaceSnapshotError.invalidIOSurface
        }

        for _ in 0 ..< 3 {
            let captureTokenBeforeRender = source.captureToken(source.ioSurface)
            guard captureTokenBeforeRender != source.previousCaptureToken else {
                return nil
            }
            let outputSurface = try makeOutputSurface(
                width: source.pixelSize.width,
                height: source.pixelSize.height,
                colorSpace: source.gpu.colorSpace
            )
            let outputBounds = CGRect(
                x: 0,
                y: 0,
                width: source.pixelSize.width,
                height: source.pixelSize.height
            )
            let sourceImage = CIImage(
                ioSurface: source.ioSurface,
                options: [.colorSpace: source.gpu.colorSpace]
            )
            let scale = min(
                outputBounds.width / CGFloat(sourceWidth),
                outputBounds.height / CGFloat(sourceHeight)
            )
            let scaledSize = CGSize(
                width: CGFloat(sourceWidth) * scale,
                height: CGFloat(sourceHeight) * scale
            )
            let transformed = sourceImage
                .transformed(by: CGAffineTransform(
                    scaleX: scale,
                    y: scale
                ))
                .transformed(by: CGAffineTransform(
                    translationX: (outputBounds.width - scaledSize.width) / 2,
                    y: (outputBounds.height - scaledSize.height) / 2
                ))
            let background = CIImage(
                color: CIColor(cgColor: opaqueFill(from: source.backgroundColor))
            ).cropped(to: outputBounds)
            source.gpu.context.render(
                transformed.composited(over: background),
                to: outputSurface,
                bounds: outputBounds,
                colorSpace: source.gpu.colorSpace
            )

            let captureToken = source.captureToken(source.ioSurface)
            guard captureToken == captureTokenBeforeRender else { continue }
            return RenderedSnapshot(
                frame: TerminalSurfacePreviewFrame(
                    ioSurface: outputSurface,
                    pixelSize: outputBounds.size
                ),
                captureToken: captureToken
            )
        }
        throw TerminalSurfaceSnapshotError.unstableIOSurface
    }

    private nonisolated static func makeOutputSurface(
        width: Int,
        height: Int,
        colorSpace: CGColorSpace
    ) throws -> IOSurface {
        guard let colorSpaceProperties = colorSpace.copyPropertyList(),
              let surface = IOSurfaceCreate([
                  kIOSurfaceWidth: width,
                  kIOSurfaceHeight: height,
                  kIOSurfaceBytesPerElement: 4,
                  kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
              ] as CFDictionary) else {
            throw TerminalSurfaceSnapshotError.outputSurfaceCreationFailed
        }
        IOSurfaceSetValue(
            surface,
            kIOSurfaceColorSpace,
            colorSpaceProperties
        )
        return surface
    }

    private nonisolated static func captureToken(
        for ioSurface: IOSurface
    ) -> TerminalSurfaceCaptureToken {
        TerminalSurfaceCaptureToken(
            surfaceID: IOSurfaceGetID(ioSurface),
            seed: IOSurfaceGetSeed(ioSurface)
        )
    }

    /// Snapshots flatten over this fill; a translucent layer color under
    /// background-opacity < 1 must not let the sidebar show through previews.
    nonisolated static func opaqueFill(from color: CGColor?) -> CGColor {
        color?.copy(alpha: 1) ?? NSColor.black.cgColor
    }
}
