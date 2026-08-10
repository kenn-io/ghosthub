import Foundation
import GhosthubWorkspace
import SwiftUI

enum ZellijSessionName {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValid(_ value: String) -> Bool {
        let name = normalized(value)
        guard name != ".", name != "..",
              !name.isEmpty,
              !name.contains("/")
        else { return false }
        return !name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        })
    }
}

struct NewZellijSessionSheet: View {
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
        let availableHosts = hosts.filter(\.zellijAvailable)
        self.hosts = availableHosts
        _selectedHost = State(initialValue:
            availableHosts.first(where: { $0.id == host.id })
                ?? availableHosts.first ?? host)
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    private var normalizedName: String {
        ZellijSessionName.normalized(sessionName)
    }

    private var existingNames: Set<String> {
        Set(selectedHost.zellijSessions.map(\.name))
    }

    private var canCreate: Bool {
        selectedHost.zellijAvailable
            && ZellijSessionName.isValid(normalizedName)
            && !existingNames.contains(normalizedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New Zellij session")
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1")
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
                .foregroundStyle(canCreate || normalizedName.isEmpty
                    ? Color.secondary : Color.red)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            Divider()

            HStack {
                Text("Zellij creates the session and Ghosthub attaches immediately.")
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
            return "Name the Zellij session you want to create."
        }
        if existingNames.contains(normalizedName) {
            return "A Zellij session named “\(normalizedName)” already exists on this host."
        }
        if !ZellijSessionName.isValid(normalizedName) {
            return "Use a nonempty name without slashes or control characters."
        }
        return "Create and attach to “\(normalizedName)”."
    }

    private func create() {
        guard canCreate else { return }
        onCreate(selectedHost, normalizedName)
    }
}
