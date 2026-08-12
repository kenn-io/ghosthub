import AppKit
import GhosthubTerminal
import GhosthubTransport
import SwiftUI

struct TmuxSessionPreviewTile: View {
    @ObservedObject var coordinator: TmuxSessionPreviewCoordinator
    let key: TmuxPreviewKey
    let sessionName: String
    let onActivate: () -> Void

    var body: some View {
        Button {
            coordinator.prepareToActivate(key, activate: onActivate)
        } label: {
            ZStack(alignment: .bottomLeading) {
                previewContent
                if let status = statusText {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.regularMaterial)
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        Color(nsColor: .separatorColor).opacity(0.5),
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var previewContent: some View {
        if let image = viewState?.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        } else {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(systemName: "terminal")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var viewState: TmuxPreviewViewState? {
        coordinator.viewState(for: key)
    }

    private var statusText: String? {
        guard let state = viewState else { return nil }
        if state.isLive {
            return "Live"
        }
        switch state.placeholder {
        case .awaitingFirstFrame: return "Open to capture"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        case .liveLimitReached: return "Live preview limit reached"
        case nil:
            guard let capturedAt = state.capturedAt else { return nil }
            return "Retained, updated \(Self.relativeFormatter.localizedString(for: capturedAt, relativeTo: Date()))"
        }
    }

    private var accessibilityLabel: String {
        let status = statusText ?? "Preview available"
        let connection = switch viewState?.connectionState {
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case nil: "connection unavailable"
        }
        return "\(sessionName), \(status), \(connection)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

struct TmuxSessionPreviewParkingView: NSViewRepresentable {
    final class ParkingContainer: NSView {
        let parkingHost = LivePreviewParkingHost(frame: .zero)
        weak var previewCoordinator: TmuxSessionPreviewCoordinator?

        init(previewCoordinator: TmuxSessionPreviewCoordinator) {
            self.previewCoordinator = previewCoordinator
            super.init(frame: .zero)
            parkingHost.frame = bounds
            parkingHost.autoresizingMask = [.width, .height]
            addSubview(parkingHost)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                previewCoordinator?.removeParkingHost(parkingHost)
            } else if let previewCoordinator {
                previewCoordinator.installParkingHost(parkingHost)
            }
        }
    }

    let previewCoordinator: TmuxSessionPreviewCoordinator

    func makeNSView(context: Context) -> ParkingContainer {
        ParkingContainer(previewCoordinator: previewCoordinator)
    }

    func updateNSView(
        _ nsView: ParkingContainer,
        context: Context
    ) {
        guard nsView.previewCoordinator !== previewCoordinator else { return }
        nsView.previewCoordinator?.removeParkingHost(nsView.parkingHost)
        nsView.previewCoordinator = previewCoordinator
        if nsView.window != nil {
            previewCoordinator.installParkingHost(nsView.parkingHost)
        }
    }

    static func dismantleNSView(
        _ nsView: ParkingContainer,
        coordinator: ()
    ) {
        nsView.previewCoordinator?.removeParkingHost(nsView.parkingHost)
        nsView.previewCoordinator = nil
    }
}
