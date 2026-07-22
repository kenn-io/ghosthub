import AppKit
import SwiftUI

public struct TerminalSurfaceRepresentable: NSViewRepresentable {
    public let surfaceView: TerminalSurfaceView

    public init(surfaceView: TerminalSurfaceView) {
        self.surfaceView = surfaceView
    }

    public func makeNSView(context _: Context) -> TerminalSurfaceView {
        surfaceView
    }

    public func updateNSView(
        _: TerminalSurfaceView, context _: Context
    ) {}
}
