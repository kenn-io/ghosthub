import GhosthubTransport
import SwiftUI

struct SSHAuthenticationPresentation: Equatable {
    let target: String
    let finalDestination: String

    init(
        target: SSHHostInfo,
        finalDestination: SSHHostInfo
    ) {
        self.target = SSHDestination.render(target)
        self.finalDestination =
            SSHDestination.render(finalDestination)
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

struct KwtSSHAuthenticationView: View {
    @ObservedObject var session: KwtSSHConnectionSession
    let onCancel: () -> Void

    @State private var response = ""
    @FocusState private var responseIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let presentation = SSHAuthenticationPresentation(
                target: session.displayHost ?? session.finalHost,
                finalDestination: session.finalHost
            )
            Text(presentation.heading)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            if let confirmation = session.hostKeyConfirmation {
                Text("Review SSH host key")
                    .font(.system(size: 14, weight: .semibold))
                Text(confirmation.destination)
                    .font(.system(size: 12, design: .monospaced))
                Text("\(confirmation.algorithm) \(confirmation.fingerprint)")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("Cancel", action: onCancel)
                    Spacer()
                    Button("Trust and Continue") {
                        session.trust(confirmation)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                switch session.state {
                case .starting, .verifying:
                    ProgressView("Preparing SSH connection…")
                    HStack {
                        Button("Cancel", action: onCancel)
                        Spacer()
                    }
                case .configurationChanged:
                    Label(
                        "SSH configuration changed",
                        systemImage: "arrow.clockwise.circle"
                    )
                    Text("Resolve the current route and try again.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel", action: onCancel)
                        Spacer()
                        Button("Try Again") { session.retry() }
                    }
                case let .prompt(prompt):
                    Text(presentation.credentialWarning)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(prompt.message)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    SecureField(
                        "Password or verification code",
                        text: $response
                    )
                    .textContentType(.password)
                    .focused($responseIsFocused)
                    .onSubmit(submit)
                    HStack {
                        Button("Cancel", action: onCancel)
                        Spacer()
                        Button("Continue", action: submit)
                            .keyboardShortcut(.defaultAction)
                    }
                    .onAppear { responseIsFocused = true }
                case .connected:
                    Label(
                        "SSH connection ready",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                case let .failed(message):
                    Label(
                        "SSH connection failed",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel", action: onCancel)
                        Spacer()
                        Button("Try Again") { session.retry() }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled()
        .onChange(of: session.state) { _, state in
            response = ""
            if case .prompt = state {
                responseIsFocused = true
            }
        }
        .onDisappear {
            response = ""
        }
    }

    private func submit() {
        let submitted = response
        response = ""
        session.submit(submitted)
    }
}
