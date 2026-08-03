import GhosthubSettings
import SwiftUI

@MainActor
final class WorkspaceSSHHostKeyReviewModel: ObservableObject {
    @Published private(set) var hostID: UUID?
    @Published private(set) var hostName = ""
    @Published private(set) var confirmation: SSHHostKeyConfirmation?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isTrusting = false

    var isPresented: Bool { hostID != nil }

    func review(
        hostID: UUID,
        hostName: String,
        using load: (UUID) async -> Result<
            SSHHostKeyConfirmation?,
            HostProbeError
        >
    ) async {
        self.hostID = hostID
        self.hostName = hostName
        confirmation = nil
        errorMessage = nil
        isLoading = true

        let result = await load(hostID)
        guard self.hostID == hostID else { return }
        isLoading = false
        switch result {
        case let .success(confirmation):
            if let confirmation {
                self.confirmation = confirmation
            } else {
                errorMessage =
                    "OpenSSH did not report an unseen host key. Use Host "
                        + "Settings to verify authentication and network access."
            }
        case let .failure(error):
            errorMessage = error.displayMessage
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
        isTrusting = true
        errorMessage = nil

        let result = await accept(hostID, confirmation)
        guard self.hostID == hostID,
              self.confirmation == confirmation else { return }
        isTrusting = false
        switch result {
        case let .success(nextConfirmation):
            if let nextConfirmation {
                self.confirmation = nextConfirmation
            } else {
                dismiss()
                onTrusted()
            }
        case let .failure(error):
            errorMessage = error.displayMessage
        }
    }

    func dismiss() {
        guard !isTrusting else { return }
        hostID = nil
        hostName = ""
        confirmation = nil
        errorMessage = nil
        isLoading = false
    }
}

struct SSHHostKeyReviewView: View {
    @ObservedObject var model: WorkspaceSSHHostKeyReviewModel
    let onTrust: () -> Void
    let onOpenHostSettings: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Trust SSH Host?", systemImage: "lock.shield")
                .font(.system(size: 20, weight: .semibold))

            if model.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Asking OpenSSH for \(model.hostName)’s host key…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let confirmation = model.confirmation {
                SSHHostKeyConfirmationDetails(confirmation: confirmation)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
                } else if !model.isLoading {
                    Button("Host Settings", action: onOpenHostSettings)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(model.isTrusting)
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
