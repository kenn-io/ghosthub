import AppKit
import CoreVideo
import GhosthubTerminalSupport
import IOSurface
import Metal

public enum TerminalSurfaceSnapshotError: Error, Equatable {
    case invalidOutputSize
    case missingIOSurface
    case imageCopyFailed
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
        let metal: MetalCaptureContext
        let captureToken: @Sendable (IOSurface) -> TerminalSurfaceCaptureToken
    }

    private struct MetalCaptureContext: @unchecked Sendable {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
    }

    private struct RenderedSnapshot: @unchecked Sendable {
        let image: CGImage
        let captureToken: TerminalSurfaceCaptureToken
    }

    private let metal: MetalCaptureContext?
    private let captureToken: @Sendable (IOSurface) -> TerminalSurfaceCaptureToken
    private var inFlight:
        [RequestKey: Task<RenderedSnapshot?, Error>] = [:]

    public convenience init() {
        self.init(captureToken: Self.captureToken)
    }

    init(
        captureToken: @escaping @Sendable (IOSurface) ->
            TerminalSurfaceCaptureToken
    ) {
        self.captureToken = captureToken
        if let device = MTLCreateSystemDefaultDevice(),
           let commandQueue = device.makeCommandQueue() {
            metal = MetalCaptureContext(
                device: device,
                commandQueue: commandQueue
            )
        } else {
            metal = nil
        }
    }

    public func snapshot(
        of surface: TerminalSurfaceView,
        outputWidth: CGFloat,
        previousCaptureToken: TerminalSurfaceCaptureToken?
    ) async throws -> TerminalSurfaceSnapshot? {
        guard outputWidth.isFinite, outputWidth > 0 else {
            throw TerminalSurfaceSnapshotError.invalidOutputSize
        }
        guard let ioSurface = surface.layer?.contents as? IOSurface else {
            throw TerminalSurfaceSnapshotError.missingIOSurface
        }
        let adaptiveSize = TerminalPreviewGeometry.thumbnailSize(
            sourceSize: CGSize(
                width: IOSurfaceGetWidth(ioSurface),
                height: IOSurfaceGetHeight(ioSurface)
            ),
            outputWidth: outputWidth
        )
        let pixelSize = (
            width: Int(adaptiveSize.width),
            height: Int(adaptiveSize.height)
        )
        let requestKey = RequestKey(
            surface: ObjectIdentifier(surface),
            width: pixelSize.width,
            height: pixelSize.height,
            previousCaptureToken: previousCaptureToken
        )
        if let pending = inFlight[requestKey] {
            guard let rendered = try await pending.value else { return nil }
            return Self.snapshot(from: rendered, pixelSize: pixelSize)
        }

        guard let metal else {
            throw TerminalSurfaceSnapshotError.imageCopyFailed
        }
        let source = RenderSource(
            ioSurface: ioSurface,
            backgroundColor: surface.layer?.backgroundColor
                ?? NSColor.black.cgColor,
            pixelSize: pixelSize,
            previousCaptureToken: previousCaptureToken,
            metal: metal,
            captureToken: captureToken
        )
        let task = Task.detached(priority: .utility) {
            try Self.makeSnapshot(source: source)
        }
        inFlight[requestKey] = task
        defer { inFlight.removeValue(forKey: requestKey) }
        guard let rendered = try await task.value else { return nil }
        return Self.snapshot(from: rendered, pixelSize: pixelSize)
    }

    private static func snapshot(
        from rendered: RenderedSnapshot,
        pixelSize: (width: Int, height: Int)
    ) -> TerminalSurfaceSnapshot {
        TerminalSurfaceSnapshot(
            image: NSImage(
                cgImage: rendered.image,
                size: CGSize(width: pixelSize.width, height: pixelSize.height)
            ),
            captureToken: rendered.captureToken
        )
    }

    private nonisolated static func makeSnapshot(
        source: RenderSource
    ) throws -> RenderedSnapshot? {
        guard IOSurfaceGetPixelFormat(source.ioSurface)
            == kCVPixelFormatType_32BGRA
        else {
            throw TerminalSurfaceSnapshotError.imageCopyFailed
        }
        let sourceWidth = IOSurfaceGetWidth(source.ioSurface)
        let sourceHeight = IOSurfaceGetHeight(source.ioSurface)
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw TerminalSurfaceSnapshotError.imageCopyFailed
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: sourceWidth,
            height: sourceHeight,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = source.metal.device.makeTexture(
            descriptor: descriptor,
            iosurface: source.ioSurface,
            plane: 0
        ) else {
            throw TerminalSurfaceSnapshotError.imageCopyFailed
        }

        for _ in 0 ..< 3 {
            let captureTokenBeforeCopy = source.captureToken(source.ioSurface)
            guard captureTokenBeforeCopy != source.previousCaptureToken else {
                return nil
            }
            let bytesPerRow = alignedBytesPerRow(sourceWidth * 4)
            guard let buffer = source.metal.device.makeBuffer(
                length: bytesPerRow * sourceHeight,
                options: .storageModeShared
            ),
                let commandBuffer = source.metal.commandQueue.makeCommandBuffer(),
                let blit = commandBuffer.makeBlitCommandEncoder()
            else {
                throw TerminalSurfaceSnapshotError.imageCopyFailed
            }
            blit.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(
                    width: sourceWidth,
                    height: sourceHeight,
                    depth: 1
                ),
                to: buffer,
                destinationOffset: 0,
                destinationBytesPerRow: bytesPerRow,
                destinationBytesPerImage: bytesPerRow * sourceHeight
            )
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else {
                throw TerminalSurfaceSnapshotError.imageCopyFailed
            }
            let captureToken = source.captureToken(source.ioSurface)
            guard captureToken == captureTokenBeforeCopy else { continue }

            let ownedPixels = Data(
                bytes: buffer.contents(),
                count: bytesPerRow * sourceHeight
            )
            guard let provider = CGDataProvider(data: ownedPixels as CFData),
                  let sourceImage = CGImage(
                      width: sourceWidth,
                      height: sourceHeight,
                      bitsPerComponent: 8,
                      bitsPerPixel: 32,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo(
                          rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                      ).union(.byteOrder32Little),
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: false,
                      intent: .defaultIntent
                  ),
                  let thumbnail = makeThumbnail(
                      sourceImage,
                      outputSize: source.pixelSize,
                      backgroundColor: source.backgroundColor
                  )
            else {
                throw TerminalSurfaceSnapshotError.imageCopyFailed
            }
            return RenderedSnapshot(
                image: thumbnail,
                captureToken: captureToken
            )
        }
        throw TerminalSurfaceSnapshotError.unstableIOSurface
    }

    private nonisolated static func captureToken(
        for ioSurface: IOSurface
    ) -> TerminalSurfaceCaptureToken {
        TerminalSurfaceCaptureToken(
            surfaceID: IOSurfaceGetID(ioSurface),
            seed: IOSurfaceGetSeed(ioSurface)
        )
    }

    private nonisolated static func alignedBytesPerRow(_ bytes: Int) -> Int {
        let alignment = 256
        return (bytes + alignment - 1) / alignment * alignment
    }

    private nonisolated static func makeThumbnail(
        _ sourceImage: CGImage,
        outputSize: (width: Int, height: Int),
        backgroundColor: CGColor
    ) -> CGImage? {
        let outputWidth = outputSize.width
        let outputHeight = outputSize.height
        let bytesPerRow = outputWidth * 4
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            ).union(.byteOrder32Little).rawValue
        ) else { return nil }
        let outputSize = CGSize(width: outputWidth, height: outputHeight)
        context.setFillColor(backgroundColor)
        context.fill(CGRect(origin: .zero, size: outputSize))
        context.interpolationQuality = .high
        let sourceSize = CGSize(
            width: sourceImage.width,
            height: sourceImage.height
        )
        let scale = min(
            outputSize.width / sourceSize.width,
            outputSize.height / sourceSize.height
        )
        let scaledSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        context.draw(
            sourceImage,
            in: CGRect(
                x: (outputSize.width - scaledSize.width) / 2,
                y: (outputSize.height - scaledSize.height) / 2,
                width: scaledSize.width,
                height: scaledSize.height
            )
        )
        return context.makeImage()
    }
}
