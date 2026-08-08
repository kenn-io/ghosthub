import GhosthubTerminal
import GhosthubTransport
import SwiftUI

struct BorrowedHerdrSessionView: View {
    var handle: BorrowedHerdrSessionHandle
    var hostName: String
    var isRemoteHost: Bool
    var connectionState: ConnectionState?
    var recoveryState: NativeSessionRecoveryState?
    var attachmentClosure: BorrowedHerdrAttachmentClosure?
    var defersTerminalResize: Bool
    var surface: () -> TerminalSurfaceView?
    var onCloseRequest: () -> Void
    var onRetryRequest: () -> Void
    var onReconnectNow: () -> Void
    var onReviewConnection: () -> Void
    var onHostSettingsRequest: () -> Void

    init(
        handle: BorrowedHerdrSessionHandle,
        hostName: String,
        isRemoteHost: Bool,
        connectionState: ConnectionState?,
        recoveryState: NativeSessionRecoveryState? = nil,
        attachmentClosure: BorrowedHerdrAttachmentClosure? = nil,
        defersTerminalResize: Bool = false,
        surface: @escaping () -> TerminalSurfaceView?,
        onCloseRequest: @escaping () -> Void,
        onRetryRequest: @escaping () -> Void,
        onReconnectNow: @escaping () -> Void = {},
        onReviewConnection: @escaping () -> Void = {},
        onHostSettingsRequest: @escaping () -> Void
    ) {
        self.handle = handle
        self.hostName = hostName
        self.isRemoteHost = isRemoteHost
        self.connectionState = connectionState
        self.recoveryState = recoveryState
        self.attachmentClosure = attachmentClosure
        self.defersTerminalResize = defersTerminalResize
        self.surface = surface
        self.onCloseRequest = onCloseRequest
        self.onRetryRequest = onRetryRequest
        self.onReconnectNow = onReconnectNow
        self.onReviewConnection = onReviewConnection
        self.onHostSettingsRequest = onHostSettingsRequest
    }

    var body: some View {
        if let surfaceView = surface() {
            NativeHerdrTerminalView(
                surfaceView: surfaceView,
                defersTerminalResize: defersTerminalResize,
                onCloseRequest: onCloseRequest
            )
        } else if recoveryState != nil {
            ContentUnavailableView {
                Label(recoveryTitle, systemImage: "network.slash")
            } description: {
                VStack(spacing: 10) {
                    if showsReconnectProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(recoveryMessage)
                        .multilineTextAlignment(.center)
                }
            } actions: {
                if primaryRecoveryActionTitle != nil {
                    Button("Reconnect Now", action: onReconnectNow)
                }
                if showsReviewConnection {
                    Button("Review Connection", action: onReviewConnection)
                }
                if showsHostSettingsAction {
                    Button("Host Settings", action: onHostSettingsRequest)
                }
            }
        } else if let disconnectionReason {
            ContentUnavailableView {
                Label(
                    disconnectionTitle,
                    systemImage: attachmentClosure == .detached
                        ? "rectangle.portrait.and.arrow.right"
                        : "network.slash"
                )
            } description: {
                Text(disconnectionReason)
            } actions: {
                Button(recoveryActionTitle, action: onRetryRequest)
                if showsHostSettingsAction {
                    Button("Host Settings", action: onHostSettingsRequest)
                }
            }
        } else {
            ProgressView("Opening \(handle.name)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var recoveryTitle: String {
        switch recoveryState {
        case .reconnecting:
            "Connection interrupted"
        case .needsAttention:
            "Connection needs attention"
        case nil:
            disconnectionTitle
        }
    }

    var recoveryMessage: String {
        switch recoveryState {
        case let .reconnecting(message), let .needsAttention(message, _):
            message
        case nil:
            disconnectionReason ?? "The Herdr session disconnected."
        }
    }

    var showsReconnectProgress: Bool {
        recoveryState?.isReconnecting == true
    }

    var primaryRecoveryActionTitle: String? {
        recoveryState?.allowsReconnectNow == true ? "Reconnect Now" : nil
    }

    var showsReviewConnection: Bool {
        guard case let .needsAttention(_, canReviewConnection) = recoveryState
        else { return false }
        return canReviewConnection
    }

    var disconnectionReason: String? {
        guard case let .disconnected(reason) = connectionState else {
            return nil
        }
        return reason ?? "The Herdr session disconnected."
    }

    var disconnectionTitle: String {
        attachmentClosure == .detached
            ? "Attachment closed"
            : "Unable to attach"
    }

    var recoveryActionTitle: String {
        attachmentClosure == .detached ? "Reconnect" : "Retry"
    }

    var showsHostSettingsAction: Bool {
        isRemoteHost && attachmentClosure != .detached
    }
}

private struct NativeHerdrTerminalView: View {
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
        .overlay(alignment: .top) {
            if let message = surfaceView.paneSplitErrorMessage {
                NativePaneSplitErrorOverlay(message: message)
            }
        }
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
