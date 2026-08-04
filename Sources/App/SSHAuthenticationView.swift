import GhosthubTmux
import SwiftUI

struct SSHAuthenticationPresentation: Equatable {
    let target: String
    let finalDestination: String

    init(
        target: SSHHostInfo,
        finalDestination: SSHHostInfo
    ) {
        self.target = SSHConfigurationResolver.proxyJumpDestination(
            for: target
        )
        self.finalDestination =
            SSHConfigurationResolver.proxyJumpDestination(
                for: finalDestination
            )
    }

    var heading: String {
        guard target != finalDestination else {
            return "Authenticate to \(target)"
        }
        return "Authenticate to \(target) to continue to \(finalDestination)"
    }

    var credentialWarning: String {
        "The prompt below is controlled by \(target). Enter only credentials"
            + " for that host."
    }
}

struct SSHAuthenticationView: View {
    @ObservedObject var session: SSHAuthenticationSession
    let finalDestination: SSHHostInfo
    @State private var response = ""
    @FocusState private var responseIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let displayHost = session.displayHost {
                let presentation = SSHAuthenticationPresentation(
                    target: displayHost,
                    finalDestination: finalDestination
                )
                Text(presentation.heading)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if case .prompt = session.state {
                    Text(presentation.credentialWarning)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch session.state {
            case .starting:
                progress("Starting OpenSSH…")
            case let .prompt(prompt):
                Text(prompt.message)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                SecureField("Password or verification code", text: $response)
                    .textContentType(.password)
                    .focused($responseIsFocused)
                    .onSubmit(submit)
                HStack {
                    Spacer()
                    Button("Continue", action: submit)
                        .keyboardShortcut(.defaultAction)
                }
                .onAppear { responseIsFocused = true }
                .onChange(of: prompt.id) { _, _ in
                    response = ""
                    responseIsFocused = true
                }
            case .verifying:
                progress("Authenticating with OpenSSH…")
            case .connected:
                Label("SSH authentication succeeded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .configurationChanged:
                progress("SSH settings changed. Restarting…")
            case let .failed(message):
                Label("SSH authentication failed", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Try Again") {
                    response = ""
                    session.retry()
                }
            }
        }
    }

    private func submit() {
        let submittedResponse = response
        response = ""
        session.submit(submittedResponse)
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(label)
        }
    }
}
