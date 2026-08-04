import SwiftUI
import GhosthubSettings
import GhosthubWorkspace

enum HostConnectionField: Hashable {
    case displayName
    case sshAddress

    static func adjacent(
        to field: Self,
        backwards: Bool
    ) -> Self? {
        switch (field, backwards) {
        case (.displayName, false):
            .sshAddress
        case (.sshAddress, true):
            .displayName
        case (.displayName, true), (.sshAddress, false):
            nil
        }
    }
}

struct HostOperationTarget: Equatable, Identifiable, Sendable {
    let draftID: UUID
    let sshDestination: String
    let platform: HostPlatform

    var id: UUID { draftID }

    init(_ draft: SSHHostDraft) {
        draftID = draft.id
        sshDestination = draft.sshDestination
        platform = draft.platform
    }

    func isCurrent(
        selectedDraftID: UUID?,
        drafts: [SSHHostDraft]
    ) -> Bool {
        guard selectedDraftID == draftID,
              let draft = drafts.first(where: { $0.id == draftID })
        else {
            return false
        }
        return draft.sshDestination == sshDestination
            && draft.platform == platform
    }
}

struct PendingSSHHostTrust: Identifiable {
    let target: HostOperationTarget
    let confirmation: SSHHostKeyConfirmation

    var id: String {
        [
            target.draftID.uuidString,
            confirmation.destination,
            confirmation.algorithm,
            confirmation.fingerprint,
        ].joined(separator: ":")
    }
}

public struct HostsSettingsView: View {
    @FocusState private var focusedConnectionField: HostConnectionField?
    @State private var remoteProjectPath = ""
    @State private var isRegisteringRemoteProject = false
    @State private var remoteProjectMessage: String?
    @State private var pendingSSHHostTrust: PendingSSHHostTrust?
    @State private var pendingSSHAuthentication: HostOperationTarget?
    @State private var sshAuthenticationSucceeded = false
    @State private var isTrustingSSHHost = false
    @State private var hostTrustErrorMessage: String?
    @Binding var sshHosts: [SSHHostDraft]
    @Binding var selectedSSHHostDraftID: UUID?
    @Binding var hostProbeResult: HostProbeSummary?
    @Binding var hostProbeErrorMessage: String?
    @Binding var isProbingSSHHost: Bool
    @Binding var isInstallingRemoteKwt: Bool
    @Binding var remoteKwtInstallMessage: String?
    @Binding var tailscalePeers: [TailscalePeer]?
    @Binding var tailscaleError: String?
    @Binding var isLoadingTailscale: Bool
    @Binding var isTailscaleSheetPresented: Bool
    @Binding var isInstallingWindowsKwt: Bool
    let probeSSHHost:
        (SSHHost) async -> Result<
            HostProbeSummary,
            HostProbeError
        >
    let pendingSSHHostKeyConfirmation:
        (SSHHost) async -> Result<
            SSHHostKeyReviewRequirement,
            HostProbeError
        >
    let trustSSHHostKey:
        (SSHHostKeyConfirmation, SSHHost) async -> Result<
            SSHHostKeyConfirmation?,
            HostProbeError
        >
    let sshAuthenticationView: (UUID, SSHHost) -> AnyView?
    let isSSHAuthenticationReady:
        (SSHHost) async -> SSHAuthenticationReadiness
    let cancelSSHAuthentication: (UUID) -> Void
    let installRemoteKwt:
        (SSHHost) async -> Result<Void, HostProbeError>
    let registerRemoteProject:
        (SSHHost, String) async -> Result<String, HostProbeError>
    let loadTailscalePeers: () async -> TailscalePeerLoadResult
    let installWindowsKwt:
        (SSHHost) async -> Result<Void, HostProbeError>

    public init(
        sshHosts: Binding<[SSHHostDraft]>,
        selectedSSHHostDraftID: Binding<UUID?>,
        hostProbeResult: Binding<HostProbeSummary?>,
        hostProbeErrorMessage: Binding<String?>,
        isProbingSSHHost: Binding<Bool>,
        isInstallingRemoteKwt: Binding<Bool>,
        remoteKwtInstallMessage: Binding<String?>,
        tailscalePeers: Binding<[TailscalePeer]?>,
        tailscaleError: Binding<String?>,
        isLoadingTailscale: Binding<Bool>,
        isTailscaleSheetPresented: Binding<Bool>,
        isInstallingWindowsKwt: Binding<Bool>,
        probeSSHHost: @escaping (SSHHost) async -> Result<
            HostProbeSummary,
            HostProbeError
        >,
        pendingSSHHostKeyConfirmation: @escaping (
            SSHHost
        ) async -> Result<SSHHostKeyReviewRequirement, HostProbeError>,
        trustSSHHostKey: @escaping (
            SSHHostKeyConfirmation,
            SSHHost
        ) async -> Result<SSHHostKeyConfirmation?, HostProbeError>,
        sshAuthenticationView: @escaping (UUID, SSHHost) -> AnyView?,
        isSSHAuthenticationReady: @escaping (
            SSHHost
        ) async -> SSHAuthenticationReadiness,
        cancelSSHAuthentication: @escaping (UUID) -> Void,
        installRemoteKwt: @escaping (
            SSHHost
        ) async -> Result<Void, HostProbeError>,
        registerRemoteProject: @escaping (
            SSHHost,
            String
        ) async -> Result<String, HostProbeError>,
        loadTailscalePeers: @escaping () async -> TailscalePeerLoadResult,
        installWindowsKwt: @escaping (SSHHost) async -> Result<
            Void,
            HostProbeError
        >
    ) {
        _sshHosts = sshHosts
        _selectedSSHHostDraftID = selectedSSHHostDraftID
        _hostProbeResult = hostProbeResult
        _hostProbeErrorMessage = hostProbeErrorMessage
        _isProbingSSHHost = isProbingSSHHost
        _isInstallingRemoteKwt = isInstallingRemoteKwt
        _remoteKwtInstallMessage = remoteKwtInstallMessage
        _tailscalePeers = tailscalePeers
        _tailscaleError = tailscaleError
        _isLoadingTailscale = isLoadingTailscale
        _isTailscaleSheetPresented = isTailscaleSheetPresented
        _isInstallingWindowsKwt = isInstallingWindowsKwt
        self.probeSSHHost = probeSSHHost
        self.pendingSSHHostKeyConfirmation =
            pendingSSHHostKeyConfirmation
        self.trustSSHHostKey = trustSSHHostKey
        self.sshAuthenticationView = sshAuthenticationView
        self.isSSHAuthenticationReady = isSSHAuthenticationReady
        self.cancelSSHAuthentication = cancelSSHAuthentication
        self.installRemoteKwt = installRemoteKwt
        self.registerRemoteProject = registerRemoteProject
        self.loadTailscalePeers = loadTailscalePeers
        self.installWindowsKwt = installWindowsKwt
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
                        "Ghosthub uses kwt, a Git worktree manager, to discover"
                            + " projects and worktrees alongside ordinary tmux"
                            + " sessions. Closing Ghosthub detaches the client"
                            + " and never kills host sessions."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Link(
                        "Learn about kwt at kwt.sh",
                        destination: URL(string: "https://kwt.sh")!
                    )
                    .font(.system(size: 12))
                }

                if let draft = selectedSSHHostDraft,
                   let binding = selectedSSHHostDraftBinding() {
                    settingsSection("Connection") {
                        hostSettingField("Display name") {
                            TextField("Office Studio", text: binding.name)
                                .textFieldStyle(.roundedBorder)
                                .focused(
                                    $focusedConnectionField,
                                    equals: .displayName
                                )
                                .onKeyPress(
                                    .tab,
                                    phases: .down
                                ) { keyPress in
                                    moveConnectionFocus(
                                        from: .displayName,
                                        backwards:
                                        keyPress.modifiers.contains(.shift)
                                    )
                                }
                        }

                        hostSettingField("SSH address") {
                            TextField("user@hostname", text: binding.sshDestination)
                                .textFieldStyle(.roundedBorder)
                                .focused(
                                    $focusedConnectionField,
                                    equals: .sshAddress
                                )
                                .onKeyPress(
                                    .tab,
                                    phases: .down
                                ) { keyPress in
                                    moveConnectionFocus(
                                        from: .sshAddress,
                                        backwards:
                                        keyPress.modifiers.contains(.shift)
                                    )
                                }
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
                                Text("Windows (psmux)")
                                    .tag(HostPlatform.windows)
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
                        Text(
                            "Test Connection follows your OpenSSH host-key"
                                + " policy. For an unseen key, Ghosthub shows"
                                + " the exact destination and fingerprint for"
                                + " approval before OpenSSH saves it. A short"
                                + " hostname or alias is a separate identity."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) {
                                Button(isProbingSSHHost ? "Testing\u{2026}" :
                                    "Test Connection") {
                                        Task {
                                            await probeHost(draft)
                                        }
                                    }
                                    .disabled(
                                        isHostActionInProgress
                                    )

                                if hostProbeResult?.host.lastKnownReachable
                                    == true {
                                    Button(remoteKwtButtonTitle) {
                                        Task {
                                            await installKwt(on: draft)
                                        }
                                    }
                                    .disabled(
                                        isHostActionInProgress
                                    )
                                }

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
                                    .disabled(
                                        isHostActionInProgress
                                    )

                                if hostProbeResult?.host.lastKnownReachable
                                    == true {
                                    Button(remoteKwtButtonTitle) {
                                        Task {
                                            await installKwt(on: draft)
                                        }
                                    }
                                    .disabled(
                                        isHostActionInProgress
                                    )
                                }

                                Button("Remove Host", role: .destructive) {
                                    removeSelectedSSHHost()
                                }
                                .disabled(sshHosts.isEmpty)
                            }
                        }

                        if draft.platform == .windows {
                            Text(
                                "Installs Ghosthub’s unsigned experimental"
                                    + " AMD64 or ARM64 kwt.exe for this user."
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                        }

                        if let hostProbeResult {
                            Text(hostProbeResult.subtitle)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(hostStatusColor(for: hostProbeResult))

                            if hostProbeResult.dependencySummary != "unknown" {
                                Text(
                                    "Dependencies: "
                                        + hostProbeResult.dependencySummary
                                )
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            }

                            if hostProbeResult.featureSummary != "unknown" {
                                Text(
                                    "Features: "
                                        + hostProbeResult.featureSummary
                                )
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            }

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
                            if let remoteKwtInstallMessage {
                                Text(remoteKwtInstallMessage)
                                    .font(.system(
                                        size: 12,
                                        weight: .semibold
                                    ))
                                    .foregroundStyle(.green)
                            }
                        } else if hostProbeErrorMessage == nil {
                            Text(
                                "Test the SSH connection before saving so tmux"
                                    + " discovery and reconnects are ready."
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        if let hostProbeErrorMessage {
                            Text(hostProbeErrorMessage)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if isRemoteKwtReady, draft.platform != .windows {
                        settingsSection("Projects") {
                            Text(
                                "Register an existing Git checkout explicitly."
                                    + " Ghosthub does not scan the remote"
                                    + " filesystem or edit kwt configuration."
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                TextField(
                                    "/absolute/path/to/repository",
                                    text: $remoteProjectPath
                                )
                                .textFieldStyle(.roundedBorder)

                                Button(
                                    isRegisteringRemoteProject
                                        ? "Adding\u{2026}"
                                        : "Add Project"
                                ) {
                                    Task {
                                        await addRemoteProject(on: draft)
                                    }
                                }
                                .disabled(
                                    isHostActionInProgress
                                        || !isRemoteProjectPathAbsolute
                                )
                            }

                            if !normalizedRemoteProjectPath.isEmpty,
                               !isRemoteProjectPathAbsolute {
                                Text("Enter an absolute path beginning with /.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                            }

                            if let remoteProjectMessage {
                                Text(remoteProjectMessage)
                                    .font(.system(
                                        size: 12,
                                        weight: .semibold
                                    ))
                                    .foregroundStyle(.green)
                            }
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
        .onChange(of: selectedSSHHostDraftID) { _, _ in
            remoteProjectPath = ""
            clearSSHHostProbeFeedback()
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
        .sheet(item: $pendingSSHHostTrust) { pending in
            sshHostTrustSheet(pending)
        }
        .sheet(item: $pendingSSHAuthentication) { target in
            sshAuthenticationSheet(target)
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
        Task { @MainActor in
            focusedConnectionField = .displayName
        }
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
                peers.map {
                    SSHHostDraftImport(tailscalePeer: $0)
                },
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
        let target = HostOperationTarget(draft)
        clearSSHHostProbeFeedback()
        isProbingSSHHost = true
        defer { isProbingSSHHost = false }

        let result = await probeSSHHost(
            draft.sshHost
        )
        guard target.isCurrent(
            selectedDraftID: selectedSSHHostDraftID,
            drafts: sshHosts
        ) else {
            return
        }
        switch result {
        case let .success(summary):
            hostProbeResult = summary
            guard let connectionDiagnostic = summary.diagnostics.first(
                where: {
                    $0.code == .sshConnectionFailed
                        || $0.code == .sshAuthenticationFailed
                }
            ) else {
                return
            }
            let trustResult = await pendingSSHHostKeyConfirmation(
                draft.sshHost
            )
            guard target.isCurrent(
                selectedDraftID: selectedSSHHostDraftID,
                drafts: sshHosts
            ) else {
                return
            }
            switch trustResult {
            case let .success(.confirmation(confirmation)):
                pendingSSHHostTrust = PendingSSHHostTrust(
                    target: target,
                    confirmation: confirmation
                )
            case .success(.authenticationRequired):
                beginSSHAuthentication(target)
            case .success(.none):
                if connectionDiagnostic.code == .sshAuthenticationFailed {
                    beginSSHAuthentication(target)
                }
            case let .failure(error):
                hostProbeErrorMessage = error.displayMessage
            }
        case let .failure(error):
            hostProbeErrorMessage = error.displayMessage
        }
    }

    private func trustHostKey(
        _ pending: PendingSSHHostTrust
    ) async {
        guard pending.target.isCurrent(
            selectedDraftID: selectedSSHHostDraftID,
            drafts: sshHosts
        ), let draft = selectedSSHHostDraft else {
            pendingSSHHostTrust = nil
            return
        }
        isTrustingSSHHost = true
        hostTrustErrorMessage = nil
        defer { isTrustingSSHHost = false }

        switch await trustSSHHostKey(
            pending.confirmation,
            draft.sshHost
        ) {
        case let .success(nextConfirmation):
            if let nextConfirmation {
                pendingSSHHostTrust = PendingSSHHostTrust(
                    target: pending.target,
                    confirmation: nextConfirmation
                )
            } else {
                pendingSSHHostTrust = nil
                beginSSHAuthentication(pending.target)
            }
        case let .failure(error):
            hostTrustErrorMessage = error.displayMessage
        }
    }

    private var remoteKwtButtonTitle: String {
        if isInstallingRemoteKwt || isInstallingWindowsKwt {
            return "Installing\u{2026}"
        }
        if selectedSSHHostDraft?.platform == .windows {
            return "Install Bundled kwt"
        }
        let isMissing = hostProbeResult?.diagnostics.contains {
            $0.code == .missingKwt
        } == true
        return isMissing
            ? "Install kwt Worktree Helper"
            : "Update kwt Worktree Helper"
    }

    private var isHostActionInProgress: Bool {
        isProbingSSHHost
            || isTrustingSSHHost
            || isInstallingRemoteKwt
            || isInstallingWindowsKwt
            || isRegisteringRemoteProject
    }

    private var isRemoteKwtReady: Bool {
        hostProbeResult?.host.lastKnownReachable == true
            && hostProbeResult?.diagnostics.contains {
                $0.code == .missingKwt
            } == false
    }

    private var normalizedRemoteProjectPath: String {
        remoteProjectPath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
    }

    private var isRemoteProjectPathAbsolute: Bool {
        normalizedRemoteProjectPath.hasPrefix("/")
    }

    private func installKwt(on draft: SSHHostDraft) async {
        if draft.platform == .windows {
            clearSSHHostProbeFeedback()
            isInstallingWindowsKwt = true
            defer { isInstallingWindowsKwt = false }

            switch await installWindowsKwt(draft.sshHost) {
            case .success:
                await probeHost(draft)
            case let .failure(error):
                hostProbeErrorMessage = error.displayMessage
            }
            return
        }

        let target = HostOperationTarget(draft)
        hostProbeErrorMessage = nil
        remoteKwtInstallMessage = nil
        isInstallingRemoteKwt = true
        defer { isInstallingRemoteKwt = false }

        let installResult = await installRemoteKwt(draft.sshHost)
        guard target.isCurrent(
            selectedDraftID: selectedSSHHostDraftID,
            drafts: sshHosts
        ) else {
            return
        }
        switch installResult {
        case .success:
            remoteKwtInstallMessage =
                "Ghosthub’s pinned kwt worktree helper is ready on this host."
            let probeResult = await probeSSHHost(draft.sshHost)
            guard target.isCurrent(
                selectedDraftID: selectedSSHHostDraftID,
                drafts: sshHosts
            ) else {
                return
            }
            switch probeResult {
            case let .success(summary):
                hostProbeResult = summary
            case let .failure(error):
                hostProbeErrorMessage = error.displayMessage
            }
        case let .failure(error):
            hostProbeErrorMessage = error.displayMessage
        }
    }

    private func addRemoteProject(on draft: SSHHostDraft) async {
        let target = HostOperationTarget(draft)
        guard isRemoteProjectPathAbsolute else { return }
        let path = normalizedRemoteProjectPath

        hostProbeErrorMessage = nil
        remoteProjectMessage = nil
        isRegisteringRemoteProject = true
        defer { isRegisteringRemoteProject = false }

        let result = await registerRemoteProject(draft.sshHost, path)
        guard target.isCurrent(
            selectedDraftID: selectedSSHHostDraftID,
            drafts: sshHosts
        ) else {
            return
        }
        switch result {
        case let .success(name):
            remoteProjectPath = ""
            remoteProjectMessage = "\(name) is now available in Ghosthub."
        case let .failure(error):
            hostProbeErrorMessage = error.displayMessage
        }
    }

    private func clearSSHHostProbeFeedback() {
        if let pendingSSHAuthentication {
            cancelSSHAuthentication(pendingSSHAuthentication.draftID)
        }
        hostProbeResult = nil
        hostProbeErrorMessage = nil
        pendingSSHHostTrust = nil
        pendingSSHAuthentication = nil
        sshAuthenticationSucceeded = false
        hostTrustErrorMessage = nil
        remoteKwtInstallMessage = nil
        remoteProjectMessage = nil
    }

    // MARK: - View Helpers

    private func sshHostTrustSheet(
        _ pending: PendingSSHHostTrust
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Trust SSH Host?", systemImage: "lock.shield")
                .font(.system(size: 20, weight: .semibold))

            SSHHostKeyConfirmationDetails(
                confirmation: pending.confirmation
            )

            if let hostTrustErrorMessage {
                Text(hostTrustErrorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    pendingSSHHostTrust = nil
                }
                .disabled(isTrustingSSHHost)
                Button(isTrustingSSHHost ? "Trusting\u{2026}" : "Trust and Continue") {
                    Task { await trustHostKey(pending) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isTrustingSSHHost)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isTrustingSSHHost)
    }

    private func sshAuthenticationSheet(
        _ target: HostOperationTarget
    ) -> some View {
        let draft = sshHosts.first { $0.id == target.draftID }
        return VStack(alignment: .leading, spacing: 16) {
            Label(
                "Authenticate with \(draft?.name ?? "SSH Host")",
                systemImage: "key"
            )
            .font(.system(size: 20, weight: .semibold))

            Text(
                "Enter the response requested by OpenSSH. Ghosthub keeps it"
                    + " only long enough to complete this connection."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if sshAuthenticationSucceeded {
                Label(
                    "Connected successfully",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
                Text(
                    "Continue to test the remote tools available to Ghosthub."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } else if let draft,
                      let authentication = sshAuthenticationView(
                          target.draftID,
                          draft.sshHost
                      ) {
                authentication
            } else {
                ContentUnavailableView(
                    "SSH Authentication Unavailable",
                    systemImage: "key.slash",
                    description: Text(
                        "Ghosthub could not start OpenSSH authentication."
                    )
                )
            }

            HStack {
                Spacer()
                if sshAuthenticationSucceeded, let draft {
                    Button("Continue") {
                        pendingSSHAuthentication = nil
                        sshAuthenticationSucceeded = false
                        Task { await probeHost(draft) }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) {
                        cancelSSHAuthentication(target.draftID)
                        pendingSSHAuthentication = nil
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .task(id: target.id) {
            await monitorSSHAuthentication(target)
        }
        .interactiveDismissDisabled()
    }

    private func monitorSSHAuthentication(
        _ target: HostOperationTarget
    ) async {
        guard let draft = sshHosts.first(where: {
            $0.id == target.draftID
        }) else { return }
        while !Task.isCancelled,
              pendingSSHAuthentication == target,
              target.isCurrent(
                  selectedDraftID: selectedSSHHostDraftID,
                  drafts: sshHosts
              ) {
            let readiness = await isSSHAuthenticationReady(
                draft.sshHost
            )
            guard !Task.isCancelled,
                  pendingSSHAuthentication == target,
                  target.isCurrent(
                      selectedDraftID: selectedSSHHostDraftID,
                      drafts: sshHosts
                  )
            else { return }
            switch readiness {
            case .pending:
                break
            case .reviewRequired:
                cancelSSHAuthentication(target.draftID)
                pendingSSHAuthentication = nil
                await probeHost(draft)
                return
            case .connected:
                cancelSSHAuthentication(target.draftID)
                sshAuthenticationSucceeded = true
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func beginSSHAuthentication(
        _ target: HostOperationTarget
    ) {
        sshAuthenticationSucceeded = false
        pendingSSHAuthentication = target
    }

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

    private func moveConnectionFocus(
        from field: HostConnectionField,
        backwards: Bool
    ) -> KeyPress.Result {
        guard let adjacent = HostConnectionField.adjacent(
            to: field,
            backwards: backwards
        ) else {
            return .ignored
        }
        focusedConnectionField = adjacent
        return .handled
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
