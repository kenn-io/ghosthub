import AppKit
import GhosthubTerminal
import GhosthubTransport
import SwiftUI

struct TmuxSessionPreviewTile: View {
    @ObservedObject var coordinator: TmuxSessionPreviewCoordinator
    let key: TmuxPreviewKey
    let sessionName: String

    var body: some View {
        Button {
            coordinator.prepareToActivate(key)
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
    final class Adapter {
        weak var previewCoordinator: TmuxSessionPreviewCoordinator?

        init(_ previewCoordinator: TmuxSessionPreviewCoordinator) {
            self.previewCoordinator = previewCoordinator
        }
    }

    let previewCoordinator: TmuxSessionPreviewCoordinator

    func makeCoordinator() -> Adapter {
        Adapter(previewCoordinator)
    }

    func makeNSView(context: Context) -> LivePreviewParkingHost {
        let host = LivePreviewParkingHost(frame: .zero)
        previewCoordinator.installParkingHost(host)
        return host
    }

    func updateNSView(
        _ nsView: LivePreviewParkingHost,
        context: Context
    ) {
        previewCoordinator.installParkingHost(nsView)
    }

    static func dismantleNSView(
        _ nsView: LivePreviewParkingHost,
        coordinator: Adapter
    ) {
        coordinator.previewCoordinator?.removeParkingHost(nsView)
    }
}
