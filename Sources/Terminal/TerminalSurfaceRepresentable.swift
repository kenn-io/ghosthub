import AppKit
import SwiftUI

public struct TerminalSurfaceRepresentable: NSViewRepresentable {
    public let surfaceView: TerminalSurfaceView
    public let defersSurfaceResize: Bool

    public init(
        surfaceView: TerminalSurfaceView,
        defersSurfaceResize: Bool = false
    ) {
        self.surfaceView = surfaceView
        self.defersSurfaceResize = defersSurfaceResize
    }

    public func makeNSView(context _: Context) -> TerminalSurfaceView {
        surfaceView.setPresentationResizeDeferred(defersSurfaceResize)
        return surfaceView
    }

    public func updateNSView(
        _ nsView: TerminalSurfaceView, context _: Context
    ) {
        nsView.setPresentationResizeDeferred(defersSurfaceResize)
    }
}
