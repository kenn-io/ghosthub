import GhosthubTerminal
import GhosthubTransport
import GhosthubUI
import SwiftUI

/// Presents one borrowed client surface, such as a Zellij session or a
/// backend terminal, with its connection and recovery states.
struct BorrowedSessionView: View {
    var sessionName: String
    var disconnectedMessage: String
    var hostName: String
    var isRemoteHost: Bool
    var connectionState: ConnectionState?
    var recoveryState: NativeSessionRecoveryState?
    var attachmentClosure: BorrowedSessionAttachmentClosure?
    var defersTerminalResize: Bool
    var surface: () -> TerminalSurfaceView?
    var onCloseRequest: () -> Void
    var onRetryRequest: () -> Void
    var onReconnectNow: () -> Void
    var onReviewConnection: () -> Void
    var onHostSettingsRequest: () -> Void
    @Environment(\.terminalBackgroundAppearance) private var backgroundAppearance

    init(
        sessionName: String,
        disconnectedMessage: String,
        hostName: String,
        isRemoteHost: Bool,
        connectionState: ConnectionState?,
        recoveryState: NativeSessionRecoveryState? = nil,
        attachmentClosure: BorrowedSessionAttachmentClosure? = nil,
        defersTerminalResize: Bool = false,
        surface: @escaping () -> TerminalSurfaceView?,
        onCloseRequest: @escaping () -> Void,
        onRetryRequest: @escaping () -> Void,
        onReconnectNow: @escaping () -> Void = {},
        onReviewConnection: @escaping () -> Void = {},
        onHostSettingsRequest: @escaping () -> Void
    ) {
        self.sessionName = sessionName
        self.disconnectedMessage = disconnectedMessage
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
            NativeBorrowedTerminalView(
                surfaceView: surfaceView,
                defersTerminalResize: defersTerminalResize,
                onCloseRequest: onCloseRequest
            )
        } else {
            sessionFallback
        }
    }

    /// Recovery, disconnection, and opening states share one chrome-tinted
    /// backdrop: the cover behind them goes clear under a transparent
    /// config, so without this they would float over the bare desktop. When
    /// opaque the tint is the canonical surface color over an identical
    /// opaque cover, so rendering is unchanged.
    private var sessionFallback: some View {
        ZStack {
            if recoveryState != nil {
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
                        attachmentClosure == .detached
                            ? "Attachment closed" : "Unable to attach",
                        systemImage: attachmentClosure == .detached
                            ? "rectangle.portrait.and.arrow.right"
                            : "network.slash"
                    )
                } description: {
                    // The heading already says a clean detach happened.
                    if attachmentClosure != .detached {
                        Text(disconnectionReason)
                    }
                } actions: {
                    Button(
                        attachmentClosure == .detached ? "Reconnect" : "Retry",
                        action: onRetryRequest
                    )
                    if showsHostSettingsAction {
                        Button("Host Settings", action: onHostSettingsRequest)
                    }
                }
            } else {
                ProgressView("Opening \(sessionName)…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceSurfaceColor.chrome(backgroundAppearance))
    }

    var recoveryTitle: String {
        switch recoveryState {
        case .reconnecting:
            "Connection interrupted"
        case .needsAttention:
            "Connection needs attention"
        case nil:
            attachmentClosure == .detached
                ? "Attachment closed" : "Unable to attach"
        }
    }

    var recoveryMessage: String {
        switch recoveryState {
        case let .reconnecting(message), let .needsAttention(message, _):
            message
        case nil:
            disconnectionReason ?? disconnectedMessage
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

    var showsHostSettingsAction: Bool {
        isRemoteHost && attachmentClosure != .detached
    }

    private var disconnectionReason: String? {
        guard case let .disconnected(reason) = connectionState else {
            return nil
        }
        return reason ?? disconnectedMessage
    }
}

private struct NativeBorrowedTerminalView: View {
    @ObservedObject var surfaceView: TerminalSurfaceView
    var defersTerminalResize: Bool
    var onCloseRequest: () -> Void
    @State private var observerID = UUID()
    @Environment(\.terminalBackgroundAppearance) private var backgroundAppearance

    var body: some View {
        TerminalSurfaceSwiftUIView(
            surfaceView: surfaceView,
            defersSurfaceResize: defersTerminalResize
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalSurfaceBackdrop.color(for: backgroundAppearance))
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
        .focusedSceneObject(surfaceView.terminalFindController)
    }
}
