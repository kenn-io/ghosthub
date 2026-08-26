import GhosthubTerminal
import GhosthubTransport
import GhosthubUI
import SwiftUI

struct BorrowedZellijSessionView: View {
    var handle: BorrowedZellijSessionHandle
    var hostName: String
    var isRemoteHost: Bool
    var connectionState: ConnectionState?
    var recoveryState: NativeSessionRecoveryState?
    var attachmentClosure: BorrowedZellijAttachmentClosure?
    var defersTerminalResize: Bool
    var surface: () -> TerminalSurfaceView?
    var onCloseRequest: () -> Void
    var onRetryRequest: () -> Void
    var onReconnectNow: () -> Void
    var onReviewConnection: () -> Void
    var onHostSettingsRequest: () -> Void

    init(
        handle: BorrowedZellijSessionHandle,
        hostName: String,
        isRemoteHost: Bool,
        connectionState: ConnectionState?,
        recoveryState: NativeSessionRecoveryState? = nil,
        attachmentClosure: BorrowedZellijAttachmentClosure? = nil,
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
            NativeZellijTerminalView(
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
            attachmentClosure == .detached
                ? "Attachment closed" : "Unable to attach"
        }
    }

    var recoveryMessage: String {
        switch recoveryState {
        case let .reconnecting(message), let .needsAttention(message, _):
            message
        case nil:
            disconnectionReason ?? "The Zellij session disconnected."
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
        return reason ?? "The Zellij session disconnected."
    }
}

private struct NativeZellijTerminalView: View {
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
    }
}
