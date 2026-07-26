import SwiftUI
import GhosthubSettings
import GhosthubWorkspace

public struct HostsSettingsView: View {
    @Binding var sshHosts: [SSHHostDraft]
    @Binding var selectedSSHHostDraftID: UUID?
    @Binding var hostProbeResult: HostProbeSummary?
    @Binding var hostProbeErrorMessage: String?
    @Binding var isProbingSSHHost: Bool
    @Binding var tailscalePeers: [TailscalePeer]?
    @Binding var tailscaleError: String?
    @Binding var isLoadingTailscale: Bool
    @Binding var isTailscaleSheetPresented: Bool
    let probeSSHHost:
        (SSHHost) async -> Result<
            HostProbeSummary,
            HostProbeError
        >
    let loadTailscalePeers: () async -> TailscalePeerLoadResult

    public init(
        sshHosts: Binding<[SSHHostDraft]>,
        selectedSSHHostDraftID: Binding<UUID?>,
        hostProbeResult: Binding<HostProbeSummary?>,
        hostProbeErrorMessage: Binding<String?>,
        isProbingSSHHost: Binding<Bool>,
        tailscalePeers: Binding<[TailscalePeer]?>,
        tailscaleError: Binding<String?>,
        isLoadingTailscale: Binding<Bool>,
        isTailscaleSheetPresented: Binding<Bool>,
        probeSSHHost: @escaping (SSHHost) async -> Result<
            HostProbeSummary,
            HostProbeError
        >,
        loadTailscalePeers: @escaping () async -> TailscalePeerLoadResult
    ) {
        _sshHosts = sshHosts
        _selectedSSHHostDraftID = selectedSSHHostDraftID
        _hostProbeResult = hostProbeResult
        _hostProbeErrorMessage = hostProbeErrorMessage
        _isProbingSSHHost = isProbingSSHHost
        _tailscalePeers = tailscalePeers
        _tailscaleError = tailscaleError
        _isLoadingTailscale = isLoadingTailscale
        _isTailscaleSheetPresented = isTailscaleSheetPresented
        self.probeSSHHost = probeSSHHost
        self.loadTailscalePeers = loadTailscalePeers
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Hosts")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        requestTailscalePeers()
                    } label: {
                        Image(systemName: "network")
                    }
                    .help("Import from Tailscale")
                    .disabled(isLoadingTailscale)
                    Button {
                        addSSHHost()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add Host")
                    Button {
                        removeSelectedSSHHost()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .help("Remove Host")
                    .disabled(sshHosts.isEmpty)
                }

                List(selection: $selectedSSHHostDraftID) {
                    ForEach(sshHosts) { host in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.listDisplayName)
                                .font(.system(
                                    size: 13, weight: .semibold
                                ))
                            Text(host.listSubtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tag(host.id)
                    }
                }
                .frame(minHeight: 300)
            }
            .frame(width: 300)

            VStack(alignment: .leading, spacing: 18) {
                settingsSection("SSH Tmux Hosts") {
                    Text(
                        "Ghosthub discovers kwt workspaces and ordinary tmux"
                            + " sessions over SSH. Closing Ghosthub detaches"
                            + " the client and never kills host sessions."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let draft = selectedSSHHostDraft,
                   let binding = selectedSSHHostDraftBinding() {
                    settingsSection("Connection") {
                        hostSettingField("Display name") {
                            TextField("Office Studio", text: binding.name)
                                .textFieldStyle(.roundedBorder)
                        }

                        hostSettingField("Identifier") {
                            TextField("office-studio", text: binding.configKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        hostSettingField("SSH address") {
                            TextField("user@hostname", text: binding.sshDestination)
                                .textFieldStyle(.roundedBorder)
                        }

                        if draft.platform == .macOS {
                            Text(
                                "Requires Remote Login enabled on the target Mac: "
                                    + "System Settings > General > Sharing > Remote Login"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        hostSettingField("Platform") {
                            Picker("Platform", selection: binding.platform) {
                                Text("Linux").tag(HostPlatform.linux)
                                Text("macOS").tag(HostPlatform.macOS)
                            }
                            .labelsHidden()
                        }

                        Text(
                            "Ghosthub uses this connection to discover tmux"
                                + " sessions and keep open attachments alive."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    settingsSection("Verification") {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Button(isProbingSSHHost ? "Testing\u{2026}" :
                                    "Test Connection") {
                                        Task {
                                            await probeHost(draft)
                                        }
                                    }
                                    .disabled(isProbingSSHHost)

                                Button("Remove Host", role: .destructive) {
                                    removeSelectedSSHHost()
                                }
                                .disabled(sshHosts.isEmpty)
                            }

                            VStack(alignment: .leading, spacing: 12) {
                                Button(isProbingSSHHost ? "Testing\u{2026}" :
                                    "Test Connection") {
                                        Task {
                                            await probeHost(draft)
                                        }
                                    }
                                    .disabled(isProbingSSHHost)

                                Button("Remove Host", role: .destructive) {
                                    removeSelectedSSHHost()
                                }
                                .disabled(sshHosts.isEmpty)
                            }
                        }

                        if let hostProbeResult {
                            Text(hostProbeResult.subtitle)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(hostStatusColor(for: hostProbeResult))

                            Text("Dependencies: \(hostProbeResult.dependencySummary)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            Text("Features: \(hostProbeResult.featureSummary)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            if !hostProbeResult.diagnostics.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(hostProbeResult.diagnostics) { diagnostic in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(diagnostic.summary)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(
                                                    diagnostic.severity == .error
                                                        ? .red
                                                        : .orange
                                                )
                                            Text(diagnostic.recoverySuggestion)
                                                .font(.system(size: 12))
                                                .foregroundStyle(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        } else if let hostProbeErrorMessage {
                            Text(hostProbeErrorMessage)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(
                                "Test the SSH connection before saving so tmux"
                                    + " discovery and reconnects are ready."
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    settingsSection("Hosts") {
                        Text(
                            "Add each machine where you keep tmux sessions."
                                + " Tailscale hostnames work well, but any"
                                + " reachable SSH destination is supported."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )

                        HStack(spacing: 8) {
                            Button(
                                "Import from Tailscale"
                            ) {
                                requestTailscalePeers()
                            }
                            .disabled(isLoadingTailscale)
                            Button(
                                "Add Host Manually",
                                action: addSSHHost
                            )
                        }
                    }
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )
        }
        .sheet(isPresented: $isTailscaleSheetPresented) {
            TailscalePeerPickerSheet(
                peers: tailscalePeers ?? [],
                existingAddresses: Set(
                    sshHosts
                        .map(\.sshDestination)
                ),
                onImport: { selected in
                    importTailscalePeers(selected)
                    isTailscaleSheetPresented = false
                },
                onCancel: {
                    isTailscaleSheetPresented = false
                }
            )
        }
        .alert(
            "Tailscale Import",
            isPresented: Binding(
                get: { tailscaleError != nil },
                set: {
                    if !$0 {
                        tailscaleError = nil
                    }
                }
            )
        ) {
            Button("OK") { tailscaleError = nil }
        } message: {
            if let error = tailscaleError {
                Text(error)
            }
        }
    }

    // MARK: - Computed Properties

    private var selectedSSHHostDraftIndex: Int? {
        sshHosts.firstIndex { draft in
            draft.id == selectedSSHHostDraftID
        }
    }

    private var selectedSSHHostDraft: SSHHostDraft? {
        get {
            guard let index = selectedSSHHostDraftIndex else {
                return nil
            }
            return sshHosts[index]
        }
        nonmutating set {
            guard let index = selectedSSHHostDraftIndex,
                  let newValue
            else {
                return
            }
            sshHosts[index] = newValue
        }
    }

    // MARK: - Binding Helpers

    private func selectedSSHHostDraftBinding() -> (
        name: Binding<String>,
        configKey: Binding<String>,
        sshDestination: Binding<String>,
        platform: Binding<HostPlatform>
    )? {
        guard let index = selectedSSHHostDraftIndex else {
            return nil
        }

        return (
            name: Binding(
                get: { sshHosts[index].name },
                set: {
                    sshHosts[index].name = $0
                    clearSSHHostProbeFeedback()
                }
            ),
            configKey: Binding(
                get: { sshHosts[index].configKey },
                set: {
                    sshHosts[index].configKey = $0
                    clearSSHHostProbeFeedback()
                }
            ),
            sshDestination: Binding(
                get: { sshHosts[index].sshDestination },
                set: {
                    sshHosts[index].sshDestination = $0
                    clearSSHHostProbeFeedback()
                }
            ),
            platform: Binding(
                get: { sshHosts[index].platform },
                set: {
                    sshHosts[index].platform = $0
                    clearSSHHostProbeFeedback()
                }
            )
        )
    }

    // MARK: - Actions

    private func addSSHHost() {
        applyDraftListState(
            SSHHostDraftListEditor.addingDefaultHost(
                to: sshHosts
            )
        )
        clearSSHHostProbeFeedback()
    }

    private func removeSelectedSSHHost() {
        applyDraftListState(
            SSHHostDraftListEditor.removingSelectedHost(
                from: sshHosts,
                selectedDraftID: selectedSSHHostDraftID
            )
        )
        clearSSHHostProbeFeedback()
    }

    private func requestTailscalePeers() {
        isLoadingTailscale = true
        tailscaleError = nil
        Task {
            let result = await loadTailscalePeers()
            isLoadingTailscale = false
            switch result {
            case let .success(peers):
                tailscalePeers = peers
                if peers.isEmpty {
                    tailscaleError = "No SSH-capable hosts"
                        + " found on your Tailscale network."
                } else {
                    isTailscaleSheetPresented = true
                }
            case let .failure(message):
                tailscaleError = message
            }
        }
    }

    private func importTailscalePeers(
        _ peers: [TailscalePeer]
    ) {
        applyDraftListState(
            SSHHostDraftListEditor.importingSSHHosts(
                peers.map(SSHHostDraftImport.init(tailscalePeer:)),
                into: sshHosts
            )
        )
        clearSSHHostProbeFeedback()
    }

    private func applyDraftListState(
        _ state: SSHHostDraftListState
    ) {
        sshHosts = state.drafts
        selectedSSHHostDraftID = state.selectedDraftID
    }

    private func probeHost(
        _ draft: SSHHostDraft
    ) async {
        clearSSHHostProbeFeedback()
        isProbingSSHHost = true
        defer { isProbingSSHHost = false }

        let result = await probeSSHHost(
            draft.sshHost
        )
        switch result {
        case let .success(summary):
            hostProbeResult = summary
        case let .failure(error):
            hostProbeErrorMessage = error.displayMessage
        }
    }

    private func clearSSHHostProbeFeedback() {
        hostProbeResult = nil
        hostProbeErrorMessage = nil
    }

    // MARK: - View Helpers

    private func hostSettingField<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            control()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hostStatusColor(
        for summary: HostProbeSummary
    ) -> Color {
        switch summary.connectionState {
        case .local, .online:
            return .primary
        case .connecting, .reconnecting, .degraded:
            return .orange
        case .offline:
            return .red
        }
    }
}
