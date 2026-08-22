import AppKit
import CoreVideo
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubTransport
import IOSurface
import SwiftUI
import Testing
@testable import GhosthubApp

@Suite("Tmux session preview tile rendering")
struct TmuxSessionPreviewTileRenderTests {
    @Test("extreme terminal shapes use bounded preview canvases", arguments: [
        (CGSize(width: 1_000_000, height: 1), CGSize(width: 320, height: 1)),
        (CGSize(width: 1, height: 1_000_000), CGSize(width: 320, height: 1_024)),
    ])
    func extremeTerminalShapesUseBoundedCanvases(
        sourceSize: CGSize,
        expectedSize: CGSize
    ) {
        #expect(TerminalPreviewGeometry.thumbnailSize(
            sourceSize: sourceSize,
            outputWidth: 320
        ) == expectedSize)
    }

    @MainActor
    @Test("GPU frames size each tile to the terminal aspect")
    func GPUFramesUseTerminalAspect() throws {
        let viewModel = TmuxPreviewViewModel()

        for (sourceSize, expectedHeight) in [
            (CGSize(width: 320, height: 160), 160),
            (CGSize(width: 320, height: 240), 240),
            (CGSize(width: 320, height: 320), 320),
            (CGSize(width: 320, height: 100), 100),
        ] {
            let ioSurface = try #require(IOSurfaceCreate([
                kIOSurfaceWidth: Int(sourceSize.width),
                kIOSurfaceHeight: Int(sourceSize.height),
                kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: Int(sourceSize.width) * 4,
                kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
            ] as CFDictionary))
            viewModel.setState(TmuxPreviewViewState(
                frame: TerminalSurfacePreviewFrame(
                    ioSurface: ioSurface,
                    pixelSize: sourceSize
                ),
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                placeholder: nil,
                connectionState: .connected,
                isLive: true
            ))
            let renderer = ImageRenderer(content: TmuxSessionPreviewTile(
                viewModel: viewModel,
                sessionName: "release-work",
                onActivate: {}
            ).frame(width: 320))
            renderer.proposedSize = ProposedViewSize(width: 320, height: nil)
            renderer.scale = 1
            let rendered = try #require(renderer.cgImage)

            #expect(CGSize(
                width: rendered.width,
                height: rendered.height
            ) == CGSize(width: 320, height: expectedHeight))
        }
    }
}
