import GhosthubSettings
import SwiftUI

enum SSHConnectionRecoveryPresentation: Equatable {
    case checking
    case hostKey
    case authentication
    case inventoryIssue
    case connectionIssue
}

@MainActor
final class WorkspaceSSHHostKeyReviewModel: ObservableObject {
    @Published private(set) var hostID: UUID?
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
        using load: () async -> SSHConnectionRecoveryResult
    ) async {
        let generation = UUID()
        self.generation = generation
        self.hostID = hostID
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
        hostName = ""
        confirmation = nil
        errorMessage = nil
        resolvedPresentation = nil
        isLoading = false
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
                    "Complete the SSH authentication prompt below. Ghosthub"
                        + " will continue automatically once OpenSSH connects."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let authenticationContent {
                    authenticationContent
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.separator, lineWidth: 1)
                        }
                } else {
                    ContentUnavailableView(
                        "SSH Terminal Unavailable",
                        systemImage: "terminal",
                        description: Text(
                            "Ghosthub could not open the authentication terminal."
                        )
                    )
                    .frame(height: 240)
                }
            }

            if let errorMessage = model.errorMessage {
                recoveryMessage(errorMessage)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(model.isTrusting)
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
            width: model.presentation == .authentication ? 720 : 520
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
                "Authenticate with \(model.hostName)",
                systemImage: "key"
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
