import AppKit
import CoreImage
import IOSurface

public enum TerminalSurfaceSnapshotError: Error, Equatable {
    case invalidOutputSize
    case missingIOSurface
    case imageCopyFailed
}

public struct TerminalSurfaceSnapshot: @unchecked Sendable {
    public let image: NSImage
    public let ioSurfaceSeed: UInt32

    public init(image: NSImage, ioSurfaceSeed: UInt32) {
        self.image = image
        self.ioSurfaceSeed = ioSurfaceSeed
    }
}

@MainActor
public final class TerminalSurfaceSnapshotter {
    private let ciContext: CIContext
    private var inFlight:
        [ObjectIdentifier: Task<TerminalSurfaceSnapshot, Error>] = [:]

    public init() {
        ciContext = CIContext(options: [
            .cacheIntermediates: false,
        ])
    }

    public func snapshot(
        of surface: TerminalSurfaceView,
        outputSize: CGSize,
        previousSeed: UInt32?
    ) async throws -> TerminalSurfaceSnapshot? {
        let pixelSize = try Self.pixelSize(for: outputSize)
        let identifier = ObjectIdentifier(surface)
        if let pending = inFlight[identifier] {
            return try await pending.value
        }

        guard let ioSurface = surface.layer?.contents as? IOSurface else {
            throw TerminalSurfaceSnapshotError.missingIOSurface
        }
        let seed = IOSurfaceGetSeed(ioSurface)
        guard seed != previousSeed else { return nil }

        let ciImage = CIImage(ioSurface: ioSurface)
        guard !ciImage.extent.isEmpty,
              let sourceImage = ciContext.createCGImage(
                  ciImage,
                  from: ciImage.extent
              )
        else {
            throw TerminalSurfaceSnapshotError.imageCopyFailed
        }
        let backgroundColor = surface.layer?.backgroundColor
            ?? NSColor.black.cgColor
        let task = Task { @MainActor in
            try Self.makeSnapshot(
                sourceImage: sourceImage,
                pixelSize: pixelSize,
                backgroundColor: backgroundColor,
                seed: seed
            )
        }
        inFlight[identifier] = task
        defer { inFlight.removeValue(forKey: identifier) }
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

    private static func makeSnapshot(
        sourceImage: CGImage,
        pixelSize: (width: Int, height: Int),
        backgroundColor: CGColor,
        seed: UInt32
    ) throws -> TerminalSurfaceSnapshot {
        guard let context = CGContext(
            data: nil,
            width: pixelSize.width,
            height: pixelSize.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TerminalSurfaceSnapshotError.imageCopyFailed
        }

        context.setFillColor(backgroundColor)
        context.fill(CGRect(
            x: 0,
            y: 0,
            width: pixelSize.width,
            height: pixelSize.height
        ))

        let sourceSize = CGSize(
            width: sourceImage.width,
            height: sourceImage.height
        )
        let outputSize = CGSize(
            width: pixelSize.width,
            height: pixelSize.height
        )
        let scale = min(
            outputSize.width / sourceSize.width,
            outputSize.height / sourceSize.height
        )
        let drawSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let drawRect = CGRect(
            x: (outputSize.width - drawSize.width) / 2,
            y: (outputSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.interpolationQuality = .high
        context.draw(sourceImage, in: drawRect)

        guard let image = context.makeImage() else {
            throw TerminalSurfaceSnapshotError.imageCopyFailed
        }
        return TerminalSurfaceSnapshot(
            image: NSImage(cgImage: image, size: outputSize),
            ioSurfaceSeed: seed
        )
    }
}
