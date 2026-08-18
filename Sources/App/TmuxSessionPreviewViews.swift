import AppKit
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubTransport
import SwiftUI

struct TmuxSessionPreviewTile: View {
    @ObservedObject var viewModel: TmuxPreviewViewModel
    let sessionName: String
    let onActivate: () -> Void

    var body: some View {
        Button {
            onActivate()
        } label: {
            ZStack(alignment: .bottomLeading) {
                previewContent
                if let status = visualStatusText {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.regularMaterial)
                }
            }
            .aspectRatio(
                TerminalPreviewGeometry.aspectRatio(
                    for: viewState?.frame?.pixelSize
                ),
                contentMode: .fit
            )
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
        if let frame = viewState?.frame {
            TmuxSessionPreviewSurface(frame: frame)
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
        viewModel.state
    }

    private var visualStatusText: String? {
        guard let state = viewState else { return nil }
        if state.isLive {
            return nil
        }
        return TmuxSessionPreviewStatus.text(
            connectionState: state.connectionState,
            placeholder: state.placeholder,
            capturedAt: state.capturedAt
        )
    }

    private var accessibilityLabel: String {
        let status = viewState?.isLive == true
            ? "Live"
            : visualStatusText ?? "Preview available"
        let connection = switch viewState?.connectionState {
        case .connecting: "connecting"
        case .reconnecting: "reconnecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case nil: "connection unavailable"
        }
        return "\(sessionName), \(status), \(connection)"
    }

}

private struct TmuxSessionPreviewSurface: NSViewRepresentable {
    let frame: TerminalSurfacePreviewFrame

    func makeNSView(context: Context) -> TerminalSurfacePreviewView {
        let view = TerminalSurfacePreviewView(frame: .zero)
        view.display(frame)
        return view
    }

    func updateNSView(
        _ nsView: TerminalSurfacePreviewView,
        context: Context
    ) {
        nsView.display(frame)
    }

    static func dismantleNSView(
        _ nsView: TerminalSurfacePreviewView,
        coordinator: Void
    ) {
        nsView.display(nil)
    }
}

enum TmuxSessionPreviewStatus {
    static func text(
        connectionState: ConnectionState?,
        placeholder: TmuxPreviewPlaceholder?,
        capturedAt: Date?,
        now: Date = Date()
    ) -> String? {
        switch connectionState {
        case .connecting:
            return "Connecting"
        case .reconnecting:
            return "Reconnecting"
        case .disconnected:
            return "Disconnected"
        case .connected, nil:
            break
        }
        switch placeholder {
        case .awaitingFirstFrame: return "Open to capture"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        case .unavailable: return "Preview unavailable"
        case .liveLimitReached: return "Live preview limit reached"
        case nil:
            guard let capturedAt else { return nil }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Retained, updated \(formatter.localizedString(for: capturedAt, relativeTo: now))"
        }
    }
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
