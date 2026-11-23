import Foundation
import GhosthubWorkspace
import SwiftUI

/// Names a new Rex session. Rex picks a name when the field is empty.
struct NewRexSessionSheet: View {
    /// Rex refuses longer session labels.
    static let maximumNameLength = 128

    let hosts: [HostSummary]
    let isCreating: Bool
    let onCreate: (HostSummary, String?) -> Void
    let onCancel: () -> Void

    @State private var selectedHost: HostSummary
    @State private var sessionName = ""
    @FocusState private var isNameFieldFocused: Bool

    init(
        host: HostSummary,
        hosts: [HostSummary],
        isCreating: Bool = false,
        onCreate: @escaping (HostSummary, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let availableHosts = hosts.filter(\.rexAvailable)
        self.hosts = availableHosts
        self.isCreating = isCreating
        _selectedHost = State(initialValue:
            availableHosts.first(where: { $0.id == host.id })
                ?? availableHosts.first ?? host)
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    private var trimmedName: String {
        sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        selectedHost.rexAvailable && trimmedName.count <= Self.maximumNameLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New Rex session")
                    .font(.headline)
                Spacer()
                NativePopupMenuButton(
                    groups: [hosts.map { host in
                        NativePopupMenuAction(host.sidebarTitle) {
                            selectedHost = host
                        }
                    }]
                ) {
                    Label(
                        selectedHost.sidebarTitle,
                        systemImage: selectedHost.kind == .selfHost
                            ? "laptopcomputer" : "server.rack"
                    )
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(isCreating)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.2x1")
                    .foregroundStyle(.secondary)
                TextField("Session name (optional)", text: $sessionName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isNameFieldFocused)
                    .onSubmit(create)
                    .disabled(isCreating)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Text(validationMessage)
                .font(.caption)
                .foregroundStyle(canCreate ? Color.secondary : Color.red)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Divider()

            HStack {
                Text("Rex opens a shell in the new session's first window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || isCreating)
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
        if trimmedName.count > Self.maximumNameLength {
            return "Use at most \(Self.maximumNameLength) characters."
        }
        if trimmedName.isEmpty {
            return "Leave the name empty and Rex chooses one."
        }
        return "Create and open “\(trimmedName)”."
    }

    private func create() {
        guard canCreate, !isCreating else { return }
        onCreate(selectedHost, trimmedName.isEmpty ? nil : trimmedName)
    }
}
