import SwiftUI

public struct TerminalSurfaceSwiftUIView: View {
    let surfaceView: TerminalSurfaceView
    @FocusState private var surfaceFocus: Bool

    public init(surfaceView: TerminalSurfaceView) {
        self.surfaceView = surfaceView
    }

    public var body: some View {
        TerminalSurfaceRepresentable(surfaceView: surfaceView)
            .id(ObjectIdentifier(surfaceView))
            .focused($surfaceFocus)
    }
}
