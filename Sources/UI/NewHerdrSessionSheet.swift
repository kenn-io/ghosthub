import Foundation
import GhosthubWorkspace
import SwiftUI

enum HerdrSessionName {
    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValid(_ value: String) -> Bool {
        let name = normalized(value)
        guard name != ".", name != "..",
              let bytes = name.data(using: .ascii),
              (1 ... 64).contains(bytes.count)
        else { return false }
        return bytes.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || byte == 46 || byte == 95 || byte == 45
        }
    }

    static func validationMessage(
        _ value: String,
        existingNames: Set<String>
    ) -> String {
        let name = normalized(value)
        if name.isEmpty {
            return "Name the Herdr session you want to create."
        }
        if existingNames.contains(name) {
            return "A Herdr session named “\(name)” already exists on this host. Restart it instead."
        }
        if !isValid(name) {
            return "Use 1–64 ASCII letters, numbers, periods, underscores, or hyphens."
        }
        return "Create and attach to “\(name)”."
    }
}

struct NewHerdrSessionSheet: View {
    let hosts: [HostSummary]
    let isCreating: Bool
    let onCreate: (HostSummary, String) -> Void
    let onCancel: () -> Void

    @State private var selectedHost: HostSummary
    @State private var sessionName = ""
    @FocusState private var isNameFieldFocused: Bool

    init(
        host: HostSummary,
        hosts: [HostSummary],
        isCreating: Bool,
        onCreate: @escaping (HostSummary, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let availableHosts = hosts.filter(\.herdrAvailable)
        self.hosts = availableHosts
        self.isCreating = isCreating
        _selectedHost = State(initialValue:
            availableHosts.first(where: { $0.id == host.id })
                ?? availableHosts.first ?? host)
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    private var normalizedName: String {
        HerdrSessionName.normalized(sessionName)
    }

    private var existingNames: Set<String> {
        Set(selectedHost.herdrSessions.map(\.name))
    }

    private var canCreate: Bool {
        !isCreating
            && selectedHost.herdrAvailable
            && HerdrSessionName.isValid(normalizedName)
            && !existingNames.contains(normalizedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("New Herdr session")
                    .font(.headline)
                Spacer()
                NativePopupMenuButton(
                    groups: [
                        hosts.map { host in
                            NativePopupMenuAction(host.sidebarTitle) {
                                selectedHost = host
                            }
                        },
                    ]
                ) {
                    Label(
                        selectedHost.sidebarTitle,
                        systemImage: selectedHost.kind == .selfHost
                            ? "laptopcomputer" : "server.rack"
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(selectedHost.sidebarTitle)
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(.secondary)
                TextField("Session name", text: $sessionName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isNameFieldFocused)
                    .onSubmit(create)
                    .disabled(isCreating)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Text(HerdrSessionName.validationMessage(
                normalizedName,
                existingNames: existingNames
            ))
            .font(.caption)
            .foregroundStyle(
                normalizedName.isEmpty || canCreate
                    ? Color.secondary : Color.red
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            HStack {
                Text("Herdr creates the session and Ghosthub attaches immediately.")
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

    private func create() {
        guard canCreate else { return }
        onCreate(selectedHost, normalizedName)
    }
}
