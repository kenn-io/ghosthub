import GhosthubWorkspace
import SwiftUI

struct RenameTmuxSessionSheet: View {
    let session: WorkspaceTmuxSessionSelection
    let existingNames: Set<String>
    let onRename: (String) async throws -> Void
    let onDismiss: () -> Void

    @State private var sessionName: String
    @State private var isRenaming = false
    @State private var failureMessage: String?
    @FocusState private var isNameFieldFocused: Bool

    init(
        session: WorkspaceTmuxSessionSelection,
        existingNames: Set<String>,
        onRename: @escaping (String) async throws -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.session = session
        self.existingNames = existingNames
        self.onRename = onRename
        self.onDismiss = onDismiss
        _sessionName = State(initialValue: session.name)
    }

    private var normalizedName: String {
        TmuxSessionName.normalized(sessionName)
    }

    private var isUnchanged: Bool {
        normalizedName == session.name
    }

    private var validationMessage: String? {
        if let failureMessage {
            return failureMessage
        }
        if isUnchanged || normalizedName.isEmpty {
            return nil
        }
        if existingNames.contains(normalizedName) {
            return "A session with this name already exists on this host."
        }
        if !TmuxSessionName.isValid(normalizedName) {
            return "Use 1–100 characters without periods, colons, or line breaks."
        }
        return nil
    }

    private var canRename: Bool {
        !isRenaming
            && !isUnchanged
            && TmuxSessionName.isValid(normalizedName)
            && !existingNames.contains(normalizedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rename tmux session")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                TextField("Session name", text: $sessionName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isNameFieldFocused)
                    .disabled(isRenaming)
                    .onSubmit(rename)
                    .onChange(of: sessionName) { _, _ in
                        failureMessage = nil
                    }
                    .accessibilityIdentifier("rename-tmux-session-name")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack {
                Spacer()
                if isRenaming {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Cancel", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isRenaming)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .interactiveDismissDisabled(isRenaming)
        .onAppear { isNameFieldFocused = true }
    }

    private func rename() {
        guard canRename else { return }
        let name = normalizedName
        isRenaming = true
        failureMessage = nil
        Task { @MainActor in
            do {
                try await onRename(name)
                onDismiss()
            } catch {
                failureMessage = error.localizedDescription
                isRenaming = false
            }
        }
    }
}
