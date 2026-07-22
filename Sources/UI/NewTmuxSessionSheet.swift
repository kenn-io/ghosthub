import GhosthubWorkspace
import SwiftUI

enum TmuxSessionName {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValid(_ value: String) -> Bool {
        let name = normalized(value)
        guard !name.isEmpty, name.count <= 100 else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && scalar != "."
                && scalar != ":"
        }
    }
}

struct NewTmuxSessionSheet: View {
    let hosts: [HostSummary]
    let onCreate: (HostSummary, String) -> Void
    let onCancel: () -> Void

    @State private var selectedHost: HostSummary
    @State private var sessionName = ""
    @FocusState private var isNameFieldFocused: Bool

    init(
        host: HostSummary,
        hosts: [HostSummary],
        onCreate: @escaping (HostSummary, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _selectedHost = State(initialValue: host)
        self.hosts = hosts
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    private var normalizedName: String {
        TmuxSessionName.normalized(sessionName)
    }

    private var existingNames: Set<String> {
        Set(selectedHost.tmuxSessions.map(\.name))
    }

    private var canCreate: Bool {
        TmuxSessionName.isValid(normalizedName)
            && !existingNames.contains(normalizedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New tmux session")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(hosts) { host in
                        Button(host.sidebarTitle) {
                            selectedHost = host
                        }
                    }
                } label: {
                    Label(
                        selectedHost.sidebarTitle,
                        systemImage: selectedHost.kind == .selfHost
                            ? "laptopcomputer" : "server.rack"
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
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
                    .onSubmit(create)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Text(validationMessage)
                .font(.caption)
                .foregroundStyle(validationMessageColor)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Divider()

            HStack {
                Text("Tmux owns the session; closing Ghosthub only detaches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onAppear { isNameFieldFocused = true }
    }

    private var validationMessage: String {
        if normalizedName.isEmpty {
            return "Name the session you want to create on this host."
        }
        if existingNames.contains(normalizedName) {
            return "A session with this name already exists on this host."
        }
        if !TmuxSessionName.isValid(normalizedName) {
            return "Use 1–100 characters without periods, colons, or line breaks."
        }
        return "Create and attach on \(selectedHost.sidebarTitle)."
    }

    private var validationMessageColor: Color {
        normalizedName.isEmpty || canCreate ? .secondary : .red
    }

    private func create() {
        guard canCreate else { return }
        onCreate(selectedHost, normalizedName)
    }
}
