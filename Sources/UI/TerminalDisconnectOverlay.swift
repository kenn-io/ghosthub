import SwiftUI

public struct TerminalDisconnectOverlay: View {
    public let isReconnecting: Bool
    public let disconnectedSince: Date?
    public let onReconnect: () -> Void
    public let onClose: () -> Void

    public init(
        isReconnecting: Bool,
        disconnectedSince: Date?,
        onReconnect: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.isReconnecting = isReconnecting
        self.disconnectedSince = disconnectedSince
        self.onReconnect = onReconnect
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.65)

            VStack(spacing: 16) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                Text("Connection lost")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                if isReconnecting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Reconnecting...")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }

                if let disconnectedSince {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = Int(context.date.timeIntervalSince(disconnectedSince))
                        Text("Disconnected \(elapsed)s ago")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }

                HStack(spacing: 12) {
                    Button("Reconnect Now") {
                        onReconnect()
                    }
                    .buttonStyle(.bordered)

                    Button("Close Pane", role: .destructive) {
                        onClose()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.top, 4)
            }
            .padding(32)
        }
    }
}
