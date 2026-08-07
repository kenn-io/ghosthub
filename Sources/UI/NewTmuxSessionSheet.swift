import Foundation
import GhosthubSettings
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

struct NewTmuxSessionLaunchSelection: Equatable, Sendable {
    private(set) var hostConfigKey: String
    private(set) var hostKind: HostKind
    private(set) var selectedProfileID: UUID?

    init(
        hostConfigKey: String,
        hostKind: HostKind,
        selectedProfileID: UUID? = nil
    ) {
        self.hostConfigKey = hostConfigKey
        self.hostKind = hostKind
        self.selectedProfileID = selectedProfileID
    }

    mutating func selectHost(configKey: String, kind: HostKind) {
        guard configKey != hostConfigKey || kind != hostKind else { return }
        hostConfigKey = configKey
        hostKind = kind
        selectedProfileID = nil
    }

    mutating func selectProfile(_ id: UUID?) {
        selectedProfileID = id
    }

    func availableProfiles(
        in configuredHosts: [SSHHost]
    ) -> [TmuxLaunchProfile] {
        // Configured SSH hosts describe remote machines, so the local host
        // never resolves profiles, even against a colliding config key.
        guard hostKind == .remote, let host = configuredHosts.first(where: {
            $0.configKey == hostConfigKey
        }), host.platform != .windows else {
            return []
        }
        return host.launchProfiles
    }

    func selectedCommand(in configuredHosts: [SSHHost]) -> String? {
        selectedProfile(in: configuredHosts)?.command
    }

    func selectedProfileName(in configuredHosts: [SSHHost]) -> String? {
        selectedProfile(in: configuredHosts)?.name
    }

    private func selectedProfile(
        in configuredHosts: [SSHHost]
    ) -> TmuxLaunchProfile? {
        guard let selectedProfileID else { return nil }
        return availableProfiles(in: configuredHosts).first {
            $0.id == selectedProfileID
        }
    }
}

struct NewTmuxSessionSheet: View {
    let hosts: [HostSummary]
    let configuredHosts: [SSHHost]
    let onCreate: (HostSummary, String, String?) -> Void
    let onCancel: () -> Void

    @State private var selectedHost: HostSummary
    @State private var launchSelection: NewTmuxSessionLaunchSelection
    @State private var sessionName = ""
    @FocusState private var isNameFieldFocused: Bool

    init(
        host: HostSummary,
        hosts: [HostSummary],
        configuredHosts: [SSHHost],
        selectedProfileID: UUID? = nil,
        onCreate: @escaping (HostSummary, String, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _selectedHost = State(initialValue: host)
        _launchSelection = State(initialValue: NewTmuxSessionLaunchSelection(
            hostConfigKey: host.configKey,
            hostKind: host.kind,
            selectedProfileID: selectedProfileID
        ))
        self.hosts = hosts
        self.configuredHosts = configuredHosts
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
                NativePopupMenuButton(
                    groups: [
                        hosts.map { host in
                            NativePopupMenuAction(host.sidebarTitle) {
                                selectedHost = host
                                launchSelection.selectHost(
                                    configKey: host.configKey,
                                    kind: host.kind
                                )
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

            if !availableProfiles.isEmpty {
                Divider()

                HStack(spacing: 12) {
                    Text("Start with")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker(
                        "Start with",
                        selection: selectedProfileBinding
                    ) {
                        Text("Login shell").tag(nil as UUID?)
                        ForEach(availableProfiles) { profile in
                            Text(profile.name).tag(profile.id as UUID?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("tmux-session-launch-profile")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }

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
        if let profileName = launchSelection.selectedProfileName(
            in: configuredHosts
        ) {
            return "Create and attach on \(selectedHost.sidebarTitle) with \(profileName)."
        }
        return "Create and attach on \(selectedHost.sidebarTitle)."
    }

    private var validationMessageColor: Color {
        normalizedName.isEmpty || canCreate ? .secondary : .red
    }

    private func create() {
        guard canCreate else { return }
        onCreate(
            selectedHost,
            normalizedName,
            launchSelection.selectedCommand(in: configuredHosts)
        )
    }

    private var availableProfiles: [TmuxLaunchProfile] {
        launchSelection.availableProfiles(in: configuredHosts)
    }

    private var selectedProfileBinding: Binding<UUID?> {
        Binding(
            get: { launchSelection.selectedProfileID },
            set: { launchSelection.selectProfile($0) }
        )
    }
}
