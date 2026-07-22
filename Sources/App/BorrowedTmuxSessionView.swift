import GhosthubTerminal
import GhosthubTmux
import SwiftUI

struct BorrowedTmuxSessionView: View {
    var handle: BorrowedTmuxSessionHandle
    var hostName: String
    var displayTitle: String?
    var connectionState: ConnectionState?
    var surface: () -> TerminalSurfaceView?
    var onCloseRequest: () -> Void
    var onRetryRequest: () -> Void

    init(
        handle: BorrowedTmuxSessionHandle,
        hostName: String,
        displayTitle: String? = nil,
        connectionState: ConnectionState?,
        surface: @escaping () -> TerminalSurfaceView?,
        onCloseRequest: @escaping () -> Void,
        onRetryRequest: @escaping () -> Void
    ) {
        self.handle = handle
        self.hostName = hostName
        self.displayTitle = displayTitle
        self.connectionState = connectionState
        self.surface = surface
        self.onCloseRequest = onCloseRequest
        self.onRetryRequest = onRetryRequest
    }

    var body: some View {
        if let surfaceView = surface() {
            NativeTmuxTerminalView(
                surfaceView: surfaceView,
                onCloseRequest: onCloseRequest
            )
        } else if let disconnectionReason {
            ContentUnavailableView {
                Label("Unable to attach", systemImage: "network.slash")
            } description: {
                Text(disconnectionReason)
            } actions: {
                Button("Retry", action: onRetryRequest)
            }
        } else {
            ProgressView("Opening \(displayTitle ?? handle.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var disconnectionReason: String? {
        guard case let .disconnected(reason) = connectionState else {
            return nil
        }
        return reason ?? "The tmux session disconnected."
    }
}

private struct NativeTmuxTerminalView: View {
    @ObservedObject var surfaceView: TerminalSurfaceView
    var onCloseRequest: () -> Void
    @State private var observerID = UUID()

    var body: some View {
        TerminalSurfaceSwiftUIView(surfaceView: surfaceView)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear {
                surfaceView.registerPaneCloseRequestObserver(
                    id: observerID,
                    onCloseRequest: onCloseRequest
                )
                surfaceView.suppressAutoFocus = false
                DispatchQueue.main.async { [surfaceView] in
                    surfaceView.requestKeyboardFocus()
                }
            }
            .onDisappear {
                surfaceView.unregisterPaneFocusObserver(id: observerID)
            }
    }
}
