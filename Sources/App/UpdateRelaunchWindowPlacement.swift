#if canImport(AppKit)
import AppKit

/// The update manifest follows logical window identity, including when a
/// missing native window must be replayed with a fresh SwiftUI scene token.
@MainActor
final class UpdateRelaunchWindowPlacement {
    private weak var window: NSWindow?
    private var pendingFrame: WorkspaceWindowFrame?

    static func capture(
        _ state: WorkspaceWindowState,
        window: NSWindow?
    ) -> WorkspaceWindowState {
        var state = state
        state.frame = nil
        // AppKit owns full-screen restoration and its separate desktop.
        if let window, !window.styleMask.contains(.fullScreen) {
            let frame = window.frame
            state.frame = WorkspaceWindowFrame(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: frame.height
            )
        }
        return state
    }

    func bind(_ window: NSWindow?) {
        self.window = window
        applyPendingFrame()
    }

    func restore(_ state: WorkspaceWindowState) {
        pendingFrame = state.frame
        applyPendingFrame()
    }

    private func applyPendingFrame() {
        guard let saved = pendingFrame, let window else { return }
        pendingFrame = nil
        guard !window.styleMask.contains(.fullScreen) else { return }
        var frame = NSRect(
            x: saved.x,
            y: saved.y,
            width: saved.width,
            height: saved.height
        )
        // Keep exact coordinates while that display is available. AppKit's
        // constraint adjusts only the vertical position and height, so also
        // bring the horizontal extent onto an available display if necessary.
        if !NSScreen.screens.contains(where: {
            $0.visibleFrame.intersects(frame)
        }), let screen = window.screen ?? NSScreen.main {
            frame.origin.x = screen.visibleFrame.minX
            frame.size.width = min(frame.width, screen.visibleFrame.width)
            frame = window.constrainFrameRect(frame, to: screen)
        }
        // Setting the frame does not order the window or activate its Space.
        window.setFrame(frame, display: false)
    }
}
#endif
