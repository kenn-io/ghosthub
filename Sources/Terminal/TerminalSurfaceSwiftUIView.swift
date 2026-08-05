import SwiftUI

public struct TerminalSurfaceSwiftUIView: View {
    let surfaceView: TerminalSurfaceView
    let defersSurfaceResize: Bool
    @FocusState private var surfaceFocus: Bool

    public init(
        surfaceView: TerminalSurfaceView,
        defersSurfaceResize: Bool = false
    ) {
        self.surfaceView = surfaceView
        self.defersSurfaceResize = defersSurfaceResize
    }

    public var body: some View {
        TerminalSurfaceRepresentable(
            surfaceView: surfaceView,
            defersSurfaceResize: defersSurfaceResize
        )
        .id(ObjectIdentifier(surfaceView))
        .focused($surfaceFocus)
    }
}
