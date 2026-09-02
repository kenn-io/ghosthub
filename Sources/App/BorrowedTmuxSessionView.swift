import GhosthubTransport
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubTmux
import GhosthubUI
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
    @Environment(\.terminalBackgroundAppearance) private var backgroundAppearance

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
            } else {
                sessionFallback
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
    @Environment(\.terminalBackgroundAppearance) private var backgroundAppearance

    var body: some View {
        TerminalSurfaceSwiftUIView(
            surfaceView: surfaceView,
            defersSurfaceResize: defersTerminalResize
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalSurfaceBackdrop.color(for: backgroundAppearance))
        .overlay(alignment: .top) {
            if let message = surfaceView.terminalOperationErrorMessage {
                NativeTerminalOperationErrorOverlay(message: message)
            }
        }
        .overlay(alignment: .topTrailing) {
            NativeTmuxFindOverlay(
                controller: surfaceView.terminalFindController,
                restoreTerminalFocus: { [weak surfaceView] in
                    surfaceView?.requestKeyboardFocus()
                }
            )
        }
        .onAppear {
            surfaceView.registerPaneCloseRequestObserver(
                id: observerID,
                onCloseRequest: onCloseRequest
            )
            surfaceView.setParkedForPreview(false)
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

private struct NativeTmuxFindOverlay: View {
    @ObservedObject var controller: TerminalFindController
    var restoreTerminalFocus: @MainActor @Sendable () -> Void

    var body: some View {
        if controller.isOpen {
            TerminalFindBar(
                controller: controller,
                restoreTerminalFocus: restoreTerminalFocus
            )
        }
    }
}
