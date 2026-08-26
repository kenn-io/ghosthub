import AppKit
import QuartzCore

/// Presents a GPU-produced terminal thumbnail through Core Animation.
@MainActor
public final class TerminalSurfacePreviewView: NSView {
    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let previewLayer = CALayer()
        previewLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.contentsGravity = .resize
        previewLayer.minificationFilter = .linear
        previewLayer.magnificationFilter = .linear
        previewLayer.actions = [
            "bounds": NSNull(),
            "contents": NSNull(),
            "contentsScale": NSNull(),
            "position": NSNull(),
        ]
        layer = previewLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func display(_ frame: TerminalSurfacePreviewFrame?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = frame?.ioSurface
        CATransaction.commit()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }
}
