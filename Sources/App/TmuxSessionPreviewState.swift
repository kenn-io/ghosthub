import Foundation
import GhosthubSettings
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
    let ioSurfaceSeed: UInt32
    let identity: TmuxSessionIdentity
}

struct TmuxSessionPreviewState<Image> {
    private(set) var visibleFrame: TmuxPreviewFrame<Image>?
    private(set) var quarantinedFrame: TmuxPreviewFrame<Image>?
    private(set) var placeholder: TmuxPreviewPlaceholder? =
        .awaitingFirstFrame

    @discardableResult
    mutating func recordCapture(
        image: Image,
        capturedAt: Date,
        ioSurfaceSeed: UInt32,
        identity: TmuxSessionIdentity
    ) -> Bool {
        if let visibleFrame,
           visibleFrame.ioSurfaceSeed == ioSurfaceSeed,
           visibleFrame.identity == identity {
            return false
        }

        visibleFrame = TmuxPreviewFrame(
            image: image,
            capturedAt: capturedAt,
            ioSurfaceSeed: ioSurfaceSeed,
            identity: identity
        )
        quarantinedFrame = nil
        placeholder = nil
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
        placeholder = .reconnecting
    }

    mutating func verifyIdentity(_ identity: TmuxSessionIdentity?) {
        guard let identity else {
            clearFrames()
            placeholder = .reconnecting
            return
        }
        guard let quarantinedFrame else {
            visibleFrame = nil
            placeholder = .awaitingFirstFrame
            return
        }
        guard quarantinedFrame.identity == identity else {
            clearFrames()
            placeholder = .awaitingFirstFrame
            return
        }

        visibleFrame = quarantinedFrame
        self.quarantinedFrame = nil
        placeholder = nil
    }

    mutating func setDisconnected() {
        placeholder = .disconnected
    }

    mutating func setLiveLimitReached(_ reached: Bool) {
        if reached {
            placeholder = .liveLimitReached
        } else if quarantinedFrame != nil {
            placeholder = .reconnecting
        } else if visibleFrame == nil {
            placeholder = .awaitingFirstFrame
        } else {
            placeholder = nil
        }
    }

    mutating func setMode(_ mode: SessionPreviewMode) {
        guard mode == .off else { return }
        clearFrames()
        placeholder = .awaitingFirstFrame
    }

    mutating func clear() {
        clearFrames()
        placeholder = .awaitingFirstFrame
    }

    private mutating func clearFrames() {
        visibleFrame = nil
        quarantinedFrame = nil
    }
}
