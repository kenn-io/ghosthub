import GhosthubTerminal
import GhosthubTmux
import SwiftUI

struct BorrowedTmuxSessionView: View {
    var handle: BorrowedTmuxSessionHandle
    var hostName: String
    var isRemoteHost: Bool
    var displayTitle: String?
    var connectionState: ConnectionState?
    var recoveryState: BorrowedTmuxRecoveryState?
    var attachmentClosure: BorrowedTmuxAttachmentClosure?
    var sessionClosed: Bool
    var defersTerminalResize: Bool
    var surface: () -> TerminalSurfaceView?
    var onCloseRequest: () -> Void
    var onRetryRequest: () -> Void
    var onReconnectNow: () -> Void
    var onReviewConnection: () -> Void
    var onHostSettingsRequest: () -> Void

    init(
        handle: BorrowedTmuxSessionHandle,
        hostName: String,
        isRemoteHost: Bool,
        displayTitle: String? = nil,
        connectionState: ConnectionState?,
        recoveryState: BorrowedTmuxRecoveryState? = nil,
        attachmentClosure: BorrowedTmuxAttachmentClosure? = nil,
        sessionClosed: Bool = false,
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
        self.displayTitle = displayTitle
        self.connectionState = connectionState
        self.recoveryState = recoveryState
        self.attachmentClosure = attachmentClosure
        self.sessionClosed = sessionClosed
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
            NativeTmuxTerminalView(
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
                    systemImage: sessionClosed
                        ? "rectangle.portrait.and.arrow.right"
                        : attachmentClosure == .detached
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
            ProgressView("Opening \(displayTitle ?? handle.name)…")
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
            disconnectionReason ?? "The tmux session disconnected."
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
        if sessionClosed {
            return "The tmux session “\(handle.name)” ended. Reopen to create"
                + " a new session with the same name."
        }
        guard case let .disconnected(reason) = connectionState else {
            return nil
        }
        return reason ?? "The tmux session disconnected."
    }

    var disconnectionTitle: String {
        if sessionClosed {
            return "Session ended"
        }
        return attachmentClosure == .detached
            ? "Attachment closed"
            : "Unable to attach"
    }

    var recoveryActionTitle: String {
        if sessionClosed {
            return "Reopen"
        }
        return attachmentClosure == .detached ? "Reconnect" : "Retry"
    }

    var showsHostSettingsAction: Bool {
        isRemoteHost && attachmentClosure != .detached && !sessionClosed
    }
}

private struct NativeTmuxTerminalView: View {
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
    }
}
