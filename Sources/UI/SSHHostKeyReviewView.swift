import GhosthubSettings
import SwiftUI

enum SSHConnectionRecoveryPresentation: Equatable {
    case checking
    case hostKey
    case authentication
    case authenticationSucceeded
    case inventoryIssue
    case connectionIssue
}

@MainActor
final class WorkspaceSSHHostKeyReviewModel: ObservableObject {
    @Published private(set) var hostID: UUID?
    @Published private(set) var tmuxRecoveryRequestID: UUID?
    @Published private(set) var hostName = ""
    @Published private(set) var confirmation: SSHHostKeyConfirmation?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isTrusting = false
    private var resolvedPresentation: SSHConnectionRecoveryPresentation?
    private var generation = UUID()

    var isPresented: Bool { hostID != nil }
    var presentation: SSHConnectionRecoveryPresentation {
        if isLoading {
            return .checking
        }
        if confirmation != nil {
            return .hostKey
        }
        return resolvedPresentation ?? .connectionIssue
    }

    func review(
        hostID: UUID,
        hostName: String,
        tmuxRecoveryRequestID: UUID? = nil,
        using load: () async -> SSHConnectionRecoveryResult
    ) async {
        let generation = UUID()
        self.generation = generation
        self.hostID = hostID
        self.tmuxRecoveryRequestID = tmuxRecoveryRequestID
        self.hostName = hostName
        confirmation = nil
        errorMessage = nil
        resolvedPresentation = nil
        isLoading = true
        isTrusting = false

        let result = await load()
        guard self.generation == generation,
              self.hostID == hostID else { return }
        isLoading = false
        switch result {
        case let .hostKey(confirmation):
            self.confirmation = confirmation
        case .authenticationRequired:
            resolvedPresentation = .authentication
        case let .inventoryIssue(message):
            resolvedPresentation = .inventoryIssue
            errorMessage = message
        case let .connectionIssue(message):
            resolvedPresentation = .connectionIssue
            errorMessage = message
        }
    }

    func trust(
        using accept: (
            UUID,
            SSHHostKeyConfirmation
        ) async -> Result<SSHHostKeyConfirmation?, HostProbeError>,
        onTrusted: () -> Void
    ) async {
        guard let hostID, let confirmation else { return }
        let generation = generation
        isTrusting = true
        errorMessage = nil

        let result = await accept(hostID, confirmation)
        guard self.generation == generation,
              self.hostID == hostID,
              self.confirmation == confirmation else { return }
        isTrusting = false
        switch result {
        case let .success(nextConfirmation):
            if let nextConfirmation {
                self.confirmation = nextConfirmation
            } else {
                self.confirmation = nil
                resolvedPresentation = .authentication
                onTrusted()
            }
        case let .failure(error):
            errorMessage = error.displayMessage
        }
    }

    func dismiss() {
        guard !isTrusting else { return }
        generation = UUID()
        hostID = nil
        tmuxRecoveryRequestID = nil
    }

    func authenticationSucceeded(onConnected: () -> Void = {}) {
        guard presentation == .authentication else { return }
        onConnected()
        resolvedPresentation = .authenticationSucceeded
    }
}

struct SSHHostKeyReviewView: View {
    @ObservedObject var model: WorkspaceSSHHostKeyReviewModel
    let onTrust: () -> Void
    let onRetry: () -> Void
    let onOpenHostSettings: () -> Void
    let onCancel: () -> Void
    let authenticationContent: AnyView?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            recoveryHeader

            if model.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking \(model.hostName) with OpenSSH…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let confirmation = model.confirmation {
                SSHHostKeyConfirmationDetails(confirmation: confirmation)
            } else if model.presentation == .authentication {
                Text(
                    "Enter the response requested by OpenSSH. Ghosthub keeps"
                        + " it only long enough to complete this connection."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let authenticationContent {
                    authenticationContent
                        .padding(.vertical, 4)
                } else {
                    ContentUnavailableView(
                        "SSH Authentication Unavailable",
                        systemImage: "key.slash",
                        description: Text(
                            "Ghosthub could not start OpenSSH authentication."
                        )
                    )
                }
            } else if model.presentation == .authenticationSucceeded {
                Label(
                    "Connected successfully",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
                Text(
                    "Ghosthub is refreshing this host’s inventory over the"
                        + " authenticated SSH connection."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            if let errorMessage = model.errorMessage {
                recoveryMessage(errorMessage)
            }

            HStack {
                Spacer()
                if model.presentation == .authenticationSucceeded {
                    Button("Done", action: onCancel)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .disabled(model.isTrusting)
                }
                if model.confirmation != nil {
                    Button(
                        model.isTrusting
                            ? "Trusting…" : "Trust and Continue",
                        action: onTrust
                    )
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isTrusting)
                } else if model.presentation == .authentication {
                    Button("Host Settings", action: onOpenHostSettings)
                } else if model.presentation == .inventoryIssue {
                    Button("Host Settings", action: onOpenHostSettings)
                    Button("Retry", action: onRetry)
                        .keyboardShortcut(.defaultAction)
                } else if !model.isLoading {
                    Button("Host Settings", action: onOpenHostSettings)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(
            width: 520
        )
        .interactiveDismissDisabled(model.isTrusting)
    }

    @ViewBuilder
    private var recoveryHeader: some View {
        switch model.presentation {
        case .checking:
            Label("Checking SSH Connection", systemImage: "network")
                .font(.system(size: 20, weight: .semibold))
        case .hostKey:
            Label("Verify SSH Host", systemImage: "lock.shield")
                .font(.system(size: 20, weight: .semibold))
        case .authentication:
            Label(
                "SSH Authentication",
                systemImage: "key"
            )
            .font(.system(size: 20, weight: .semibold))
        case .authenticationSucceeded:
            Label(
                "Connected to \(model.hostName)",
                systemImage: "checkmark.circle"
            )
            .font(.system(size: 20, weight: .semibold))
        case .inventoryIssue:
            Label(
                "Connected, but Inventory Failed",
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 20, weight: .semibold))
        case .connectionIssue:
            Label(
                "Can’t Connect to \(model.hostName)",
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 20, weight: .semibold))
        }
    }

    @ViewBuilder
    private func recoveryMessage(_ message: String) -> some View {
        if model.presentation == .inventoryIssue {
            Text(message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SSHHostKeyConfirmationDetails: View {
    let confirmation: SSHHostKeyConfirmation

    var body: some View {
        Text(
            "OpenSSH reported a previously unseen host key while "
                + "connecting to this exact destination:"
        )
        Text(confirmation.connectionDestination)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)

        VStack(alignment: .leading, spacing: 6) {
            Text("Host named by OpenSSH")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(confirmation.destination)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text(confirmation.algorithm)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(confirmation.fingerprint)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("OpenSSH details")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(confirmation.openSSHPrompt)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.secondary.opacity(0.08))
                )
        }

        Text(
            "Verify this fingerprint through a trusted channel. Trusting "
                + "it authorizes OpenSSH to save only the key shown above "
                + "for this destination."
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
