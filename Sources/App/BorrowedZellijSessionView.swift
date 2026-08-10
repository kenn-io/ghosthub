import GhosthubTerminal
import GhosthubTransport
import SwiftUI

struct BorrowedZellijSessionView: View {
    var handle: BorrowedZellijSessionHandle
    var isRemoteHost: Bool
    var connectionState: ConnectionState?
    var attachmentClosure: BorrowedZellijAttachmentClosure?
    var defersTerminalResize: Bool
    var surface: () -> TerminalSurfaceView?
    var onCloseRequest: () -> Void
    var onRetryRequest: () -> Void
    var onHostSettingsRequest: () -> Void

    var body: some View {
        if let surfaceView = surface() {
            NativeZellijTerminalView(
                surfaceView: surfaceView,
                defersTerminalResize: defersTerminalResize,
                onCloseRequest: onCloseRequest
            )
        } else if let disconnectionReason {
            ContentUnavailableView {
                Label(
                    attachmentClosure == .detached
                        ? "Attachment closed" : "Unable to attach",
                    systemImage: attachmentClosure == .detached
                        ? "rectangle.portrait.and.arrow.right"
                        : "network.slash"
                )
            } description: {
                Text(disconnectionReason)
            } actions: {
                Button(
                    attachmentClosure == .detached ? "Reconnect" : "Retry",
                    action: onRetryRequest
                )
                if isRemoteHost, attachmentClosure != .detached {
                    Button("Host Settings", action: onHostSettingsRequest)
                }
            }
        } else {
            ProgressView("Opening \(handle.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var disconnectionReason: String? {
        guard case let .disconnected(reason) = connectionState else {
            return nil
        }
        return reason ?? "The Zellij session disconnected."
    }
}

private struct NativeZellijTerminalView: View {
    @ObservedObject var surfaceView: TerminalSurfaceView
    var defersTerminalResize: Bool
    var onCloseRequest: () -> Void
    @State private var observerID = UUID()

    var body: some View {
        TerminalSurfaceSwiftUIView(
            surfaceView: surfaceView,
            defersSurfaceResize: defersTerminalResize
        )
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
        .focusedSceneValue(
            \.terminalHasEffectiveKeyboardFocus,
            surfaceView.hasEffectiveKeyboardFocus
        )
    }
}
