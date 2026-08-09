import GhosthubTransport
import GhosthubTerminal
import GhosthubTmux
import SwiftUI

struct BorrowedTmuxSessionView: View {
    var handle: BorrowedTmuxSessionHandle
    var hostName: String
    var isRemoteHost: Bool
    var displayTitle: String?
    var connectionState: ConnectionState?
    var recoveryState: NativeSessionRecoveryState?
    var attachmentClosure: BorrowedTmuxAttachmentClosure?
    var sessionClosed: Bool
    var defersTerminalResize: Bool
    var retryRequiresConfirmation: Bool
    var retryCommand: String?
    var surface: () -> TerminalSurfaceView?
    var onCloseRequest: () -> Void
    var onRetryRequest: () -> Void
    var onConfirmedRetryRequest: () -> Void
    var onReconnectNow: () -> Void
    var onReviewConnection: () -> Void
    var onHostSettingsRequest: () -> Void
    @State private var isRetryConfirmationPresented = false

    init(
        handle: BorrowedTmuxSessionHandle,
        hostName: String,
        isRemoteHost: Bool,
        displayTitle: String? = nil,
        connectionState: ConnectionState?,
        recoveryState: NativeSessionRecoveryState? = nil,
        attachmentClosure: BorrowedTmuxAttachmentClosure? = nil,
        sessionClosed: Bool = false,
        defersTerminalResize: Bool = false,
        retryRequiresConfirmation: Bool = false,
        retryCommand: String? = nil,
        surface: @escaping () -> TerminalSurfaceView?,
        onCloseRequest: @escaping () -> Void,
        onRetryRequest: @escaping () -> Void,
        onConfirmedRetryRequest: @escaping () -> Void = {},
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
        self.retryRequiresConfirmation = retryRequiresConfirmation
        self.retryCommand = retryCommand
        self.surface = surface
        self.onCloseRequest = onCloseRequest
        self.onRetryRequest = onRetryRequest
        self.onConfirmedRetryRequest = onConfirmedRetryRequest
        self.onReconnectNow = onReconnectNow
        self.onReviewConnection = onReviewConnection
        self.onHostSettingsRequest = onHostSettingsRequest
    }

    var body: some View {
        Group {
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
                    Button(recoveryActionTitle) {
                        if retryRequiresConfirmation {
                            isRetryConfirmationPresented = true
                        } else {
                            onRetryRequest()
                        }
                    }
                    if showsHostSettingsAction {
                        Button("Host Settings", action: onHostSettingsRequest)
                    }
                }
            } else {
                ProgressView("Opening \(displayTitle ?? handle.name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog(
            "Run the launch command again?",
            isPresented: $isRetryConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Run Command Again", role: .destructive) {
                onConfirmedRetryRequest()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "The command may have started before the connection "
                        + "dropped. Running it again could repeat its side "
                        + "effects."
                )
                if let retryConfirmationCommand {
                    Text(retryConfirmationCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
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
        if retryRequiresConfirmation {
            return "Retry Command"
        }
        return attachmentClosure == .detached ? "Reconnect" : "Retry"
    }

    var retryConfirmationCommand: String? {
        retryRequiresConfirmation ? retryCommand : nil
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
