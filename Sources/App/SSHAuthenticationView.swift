import SwiftUI

struct SSHAuthenticationView: View {
    @ObservedObject var session: SSHAuthenticationSession
    @State private var response = ""
    @FocusState private var responseIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                        .disabled(response.isEmpty)
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
        guard !response.isEmpty else { return }
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
