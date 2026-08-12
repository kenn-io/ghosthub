import Foundation
import GhosthubSettings
import GhosthubTerminal
import GhosthubTmux

enum TmuxPreviewPlaceholder: Equatable, Sendable {
    case awaitingFirstFrame
    case reconnecting
    case disconnected
    case liveLimitReached
}

struct TmuxPreviewFrame<Image> {
    let image: Image
    let capturedAt: Date
    let captureToken: TerminalSurfaceCaptureToken
    let identity: TmuxSessionIdentity
}

struct TmuxSessionPreviewState<Image> {
    private(set) var visibleFrame: TmuxPreviewFrame<Image>?
    private(set) var quarantinedFrame: TmuxPreviewFrame<Image>?
    private var connectionPlaceholder: TmuxPreviewPlaceholder? =
        .awaitingFirstFrame
    private var isLiveLimitReached = false

    var placeholder: TmuxPreviewPlaceholder? {
        switch connectionPlaceholder {
        case .reconnecting, .disconnected:
            connectionPlaceholder
        default:
            isLiveLimitReached ? .liveLimitReached : connectionPlaceholder
        }
    }

    @discardableResult
    mutating func recordCapture(
        image: Image,
        capturedAt: Date,
        captureToken: TerminalSurfaceCaptureToken,
        identity: TmuxSessionIdentity
    ) -> Bool {
        if let visibleFrame,
           visibleFrame.captureToken == captureToken,
           visibleFrame.identity == identity {
            return false
        }

        visibleFrame = TmuxPreviewFrame(
            image: image,
            capturedAt: capturedAt,
            captureToken: captureToken,
            identity: identity
        )
        quarantinedFrame = nil
        connectionPlaceholder = nil
        return true
    }

    mutating func recordCaptureFailure() {
        // Preserve the last valid frame and its authorization metadata.
    }

    mutating func beginReconnect() {
        if let visibleFrame {
            quarantinedFrame = visibleFrame
        }
        visibleFrame = nil
        connectionPlaceholder = .reconnecting
    }

    mutating func verifyIdentity(_ identity: TmuxSessionIdentity?) {
        guard let identity else {
            clearFrames()
            connectionPlaceholder = .reconnecting
            return
        }
        if let visibleFrame {
            guard visibleFrame.identity == identity else {
                clearFrames()
                connectionPlaceholder = .awaitingFirstFrame
                return
            }
            connectionPlaceholder = nil
            return
        }
        guard let quarantinedFrame else {
            connectionPlaceholder = .awaitingFirstFrame
            return
        }
        guard quarantinedFrame.identity == identity else {
            clearFrames()
            connectionPlaceholder = .awaitingFirstFrame
            return
        }

        visibleFrame = quarantinedFrame
        self.quarantinedFrame = nil
        connectionPlaceholder = nil
    }

    mutating func setDisconnected() {
        if let visibleFrame {
            quarantinedFrame = visibleFrame
        }
        visibleFrame = nil
        connectionPlaceholder = .disconnected
    }

    mutating func setLiveLimitReached(_ reached: Bool) {
        isLiveLimitReached = reached
    }

    mutating func setMode(_ mode: SessionPreviewMode) {
        guard mode == .off else { return }
        clearFrames()
        connectionPlaceholder = .awaitingFirstFrame
        isLiveLimitReached = false
    }

    mutating func clear() {
        clearFrames()
        connectionPlaceholder = .awaitingFirstFrame
        isLiveLimitReached = false
    }

    private mutating func clearFrames() {
        visibleFrame = nil
        quarantinedFrame = nil
    }
}
