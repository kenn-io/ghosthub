import AppKit
import Combine
import GhosthubSettings
import SwiftUI
import GhosthubWorkspace

public struct SettingsActions {
    var refreshHosts: () -> Void = {}
    var probeSSHHost:
        (SSHHost) async -> Result<
            HostProbeSummary,
            HostProbeError
        > = { _ in
            .failure(.message("SSH host probing is unavailable."))
        }
    var pendingSSHHostKeyConfirmation:
        (SSHHost) async -> Result<
            SSHHostKeyReviewRequirement,
            HostProbeError
        > = { _ in .success(.none) }
    var trustSSHHostKey:
        (SSHHostKeyConfirmation, SSHHost) async -> Result<
            SSHHostKeyConfirmation?,
            HostProbeError
        > = { _, _ in
            .failure(.message("SSH host-key approval is unavailable."))
        }
    var sshAuthenticationView: (UUID, SSHHost) -> AnyView? = { _, _ in nil }
    var isSSHAuthenticationReady:
        (SSHHost) async -> SSHAuthenticationReadiness = { _ in .pending }
    var cancelSSHAuthentication: (UUID) -> Void = { _ in }
    var loadTailscalePeers: () async -> TailscalePeerLoadResult = {
        .failure("Tailscale import is unavailable.")
    }
    var exeAccountStatusesPublisher:
        AnyPublisher<[String: ExeAccountStatus], Never> = Just([:])
        .eraseToAnyPublisher()
    var probeExeAccountConnection:
        (ExeAccount) async -> ExeAccountConnectionProbeResult = { _ in
            .failed("exe.dev connection probing is unavailable.")
        }
    var refreshExeAccounts:
        ([ExeAccount], [String: [ExeVMRecord]]) -> UUID? = { _, _ in nil }
    var cancelExeAccountRefresh: (UUID) -> Void = { _ in }
    var invalidateExeAccountRefresh: (UUID, [ExeAccount]) -> Void = { _, _ in }
    var installRemoteKwt:
        (SSHHost) async -> Result<Void, HostProbeError> = { _ in
            .failure(.message("Remote kwt installation is unavailable."))
        }
    var registerRemoteProject:
        (SSHHost, String) async -> Result<String, HostProbeError> = {
            _, _ in
            .failure(.message("Remote project registration is unavailable."))
        }
    var installWindowsKwt:
        (SSHHost) async -> Result<Void, HostProbeError> = { _ in
            .failure(.message("Windows kwt installation is unavailable."))
        }
    var reloadTerminalConfig: () -> Void = {}

    public init(
        refreshHosts: @escaping () -> Void = {},
        probeSSHHost: @escaping (SSHHost) async -> Result<
            HostProbeSummary,
            HostProbeError
        > = { _ in
            .failure(.message("SSH host probing is unavailable."))
        },
        pendingSSHHostKeyConfirmation: @escaping (
            SSHHost
        ) async -> Result<SSHHostKeyReviewRequirement, HostProbeError> = {
            _ in .success(.none)
        },
        trustSSHHostKey: @escaping (
            SSHHostKeyConfirmation,
            SSHHost
        ) async -> Result<SSHHostKeyConfirmation?, HostProbeError> = { _, _ in
            .failure(.message("SSH host-key approval is unavailable."))
        },
        sshAuthenticationView: @escaping (UUID, SSHHost) -> AnyView? = {
            _, _ in nil
        },
        isSSHAuthenticationReady: @escaping (
            SSHHost
        ) async -> SSHAuthenticationReadiness = {
            _ in .pending
        },
        cancelSSHAuthentication: @escaping (UUID) -> Void = { _ in },
        loadTailscalePeers: @escaping () async -> TailscalePeerLoadResult = {
            .failure("Tailscale import is unavailable.")
        },
        exeAccountStatusesPublisher:
        AnyPublisher<[String: ExeAccountStatus], Never> = Just([:])
            .eraseToAnyPublisher(),
        probeExeAccountConnection: @escaping (
            ExeAccount
        ) async -> ExeAccountConnectionProbeResult = { _ in
            .failed("exe.dev connection probing is unavailable.")
        },
        refreshExeAccounts: @escaping (
            [ExeAccount],
            [String: [ExeVMRecord]]
        ) -> UUID? = { _, _ in nil },
        cancelExeAccountRefresh: @escaping (UUID) -> Void = { _ in },
        invalidateExeAccountRefresh: @escaping (
            UUID,
            [ExeAccount]
        ) -> Void = { _, _ in },
        installRemoteKwt: @escaping (
            SSHHost
        ) async -> Result<Void, HostProbeError> = { _ in
            .failure(.message("Remote kwt installation is unavailable."))
        },
        registerRemoteProject: @escaping (
            SSHHost,
            String
        ) async -> Result<String, HostProbeError> = { _, _ in
            .failure(.message("Remote project registration is unavailable."))
        },
        installWindowsKwt: @escaping (SSHHost) async -> Result<
            Void,
            HostProbeError
        > = { _ in
            .failure(.message("Windows kwt installation is unavailable."))
        },
        reloadTerminalConfig: @escaping () -> Void = {}
    ) {
        self.refreshHosts = refreshHosts
        self.probeSSHHost = probeSSHHost
        self.pendingSSHHostKeyConfirmation =
            pendingSSHHostKeyConfirmation
        self.trustSSHHostKey = trustSSHHostKey
        self.sshAuthenticationView = sshAuthenticationView
        self.isSSHAuthenticationReady = isSSHAuthenticationReady
        self.cancelSSHAuthentication = cancelSSHAuthentication
        self.loadTailscalePeers = loadTailscalePeers
        self.exeAccountStatusesPublisher = exeAccountStatusesPublisher
        self.probeExeAccountConnection = probeExeAccountConnection
        self.refreshExeAccounts = refreshExeAccounts
        self.cancelExeAccountRefresh = cancelExeAccountRefresh
        self.invalidateExeAccountRefresh = invalidateExeAccountRefresh
        self.installRemoteKwt = installRemoteKwt
        self.registerRemoteProject = registerRemoteProject
        self.installWindowsKwt = installWindowsKwt
        self.reloadTerminalConfig = reloadTerminalConfig
    }
}

public struct SettingsView: View {
    private static let minSheetWidth: CGFloat = 1040
    private static let minSheetHeight: CGFloat = 680

    @ObservedObject private var store: SettingsStore
    private let actions: SettingsActions
    private let showsToolbar: Bool
    private let simplifiedForTesting: Bool
    private let defaultFontSizes: [Double] = [10, 11, 12, 13, 14, 15, 16, 18, 20, 24]
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SettingsViewDraft
    @State private var hostProbeResult: HostProbeSummary?
    @State private var hostProbeErrorMessage: String?
    @State private var isProbingHost = false
    @State private var isInstallingRemoteKwt = false
    @State private var remoteKwtInstallMessage: String?
    @State private var tailscalePeers: [TailscalePeer]?
    @State private var tailscaleError: String?
    @State private var isLoadingTailscale = false
    @State private var isTailscaleSheetPresented = false
    @State private var isInstallingWindowsKwt = false
    public init(
        store: SettingsStore,
        actions: SettingsActions = SettingsActions(),
        showsToolbar: Bool = true,
        simplifiedForTesting: Bool = false
    ) {
        _store = ObservedObject(wrappedValue: store)
        self.actions = actions
        self.showsToolbar = showsToolbar
        self.simplifiedForTesting = simplifiedForTesting

        _draft = State(
            initialValue: SettingsViewDraft(
                store: store
            )
        )
    }

    public var body: some View {
        settingsContent
            .presentationSizing(.form)
            .onDisappear {
                persist()
            }
            .onChange(of: draft.selectedSSHHostDraftID) { _, _ in
                hostProbeResult = nil
                hostProbeErrorMessage = nil
                remoteKwtInstallMessage = nil
            }
    }

    @ViewBuilder
    private var settingsContent: some View {
        let content = NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: 190,
                    ideal: 210,
                    max: 240
                )
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    detail
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(paneFill)
        }
        .frame(
            minWidth: Self.minSheetWidth,
            minHeight: Self.minSheetHeight
        )
        if showsToolbar {
            content.toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if persist().didPersistTmuxSessionPatterns {
                            dismiss()
                        }
                    }
                }
            }
        } else {
            content
        }
    }

    private var sidebar: some View {
        List(selection: $draft.selectedDomain) {
            Section("Settings") {
                ForEach(SettingsDomain.allCases) { domain in
                    Label(
                        domain.title,
                        systemImage: domain.systemImageName
                    )
                    .tag(domain)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if simplifiedForTesting {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 1)
        } else {
            switch draft.selectedDomain {
            case .appearance:
                appearanceDetail
            case .terminal:
                terminalDetail
            case .keyboard:
                keyboardDetail
            case .worktrees:
                worktreesDetail
            case .agents:
                agentsDetail
            case .privacy:
                privacyDetail
            case .hosts:
                hostsDetail
            case .integrations:
                integrationsDetail
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.selectedDomain.title)
                .font(.system(size: 24, weight: .bold))

            Text(draft.selectedDomain.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            if let lastErrorMessage = store.lastErrorMessage {
                Text(lastErrorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            }
        }
    }

    private var availableTerminalFontFamilies: [String] {
        let manager = NSFontManager.shared
        let installedFixedPitchFamilies = manager.availableFontFamilies.filter { family in
            manager.availableMembers(ofFontFamily: family)?.contains {
                member in
                guard member.count > 3 else { return false }
                if let traits = member[3] as? NSNumber,
                   NSFontTraitMask(rawValue: traits.uintValue)
                   .contains(.fixedPitchFontMask) {
                    return true
                }
                guard let fontName = member[0] as? String,
                      let font = NSFont(name: fontName, size: 14)
                else { return false }
                if font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                    return true
                }
                let advances = ["i", "W", "0", "m", " "].map {
                    ($0 as NSString).size(withAttributes: [.font: font]).width
                }
                guard let minimum = advances.min(),
                      let maximum = advances.max()
                else { return false }
                return maximum - minimum < 0.01
            } == true
        }
        return TerminalFontFamilyOptions.families(
            installedFixedPitch: installedFixedPitchFamilies,
            configured: draft.terminalFontFamily
        )
    }

    private var availableTerminalFontSizes: [Double] {
        let roundedCurrent = (draft.terminalFontSize * 2).rounded() / 2
        let sizes = Set(defaultFontSizes + [roundedCurrent])
        return sizes.sorted()
    }

    private var hostsDetail: some View {
        HostsSettingsView(
            sshHosts: $draft.sshHosts,
            selectedSSHHostDraftID: $draft.selectedSSHHostDraftID,
            hostProbeResult: $hostProbeResult,
            hostProbeErrorMessage: $hostProbeErrorMessage,
            isProbingSSHHost: $isProbingHost,
            isInstallingRemoteKwt: $isInstallingRemoteKwt,
            remoteKwtInstallMessage: $remoteKwtInstallMessage,
            tailscalePeers: $tailscalePeers,
            tailscaleError: $tailscaleError,
            isLoadingTailscale: $isLoadingTailscale,
            isTailscaleSheetPresented: $isTailscaleSheetPresented,
            isInstallingWindowsKwt: $isInstallingWindowsKwt,
            probeSSHHost: actions.probeSSHHost,
            pendingSSHHostKeyConfirmation:
            actions.pendingSSHHostKeyConfirmation,
            trustSSHHostKey: actions.trustSSHHostKey,
            sshAuthenticationView: actions.sshAuthenticationView,
            isSSHAuthenticationReady:
            actions.isSSHAuthenticationReady,
            cancelSSHAuthentication:
            actions.cancelSSHAuthentication,
            installRemoteKwt: actions.installRemoteKwt,
            registerRemoteProject: actions.registerRemoteProject,
            loadTailscalePeers: actions.loadTailscalePeers,
            installWindowsKwt: actions.installWindowsKwt
        )
    }

    private var integrationsDetail: some View {
        ExeAccountsSettingsView(
            accounts: $draft.exeAccounts,
            statusesPublisher: actions.exeAccountStatusesPublisher,
            pendingSSHHostKeyConfirmation:
            actions.pendingSSHHostKeyConfirmation,
            trustSSHHostKey: actions.trustSSHHostKey,
            sshAuthenticationView: actions.sshAuthenticationView,
            isSSHAuthenticationReady:
            actions.isSSHAuthenticationReady,
            cancelSSHAuthentication:
            actions.cancelSSHAuthentication,
            probeConnection: actions.probeExeAccountConnection,
            refresh: actions.refreshExeAccounts,
            cancelRefresh: actions.cancelExeAccountRefresh,
            invalidateRefresh: actions.invalidateExeAccountRefresh
        )
    }

    private var terminalDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("Interaction") {
                Toggle("Hide the mouse while typing", isOn: $draft.hideMouseWhileTyping)
                Toggle(
                    "Copy selections directly to the clipboard",
                    isOn: $draft.copySelectionToClipboard
                )

                Text(
                    "These settings stay in Ghosthub’s managed terminal block inside ghostty.conf. Built-in themes and font overrides are handled separately in Appearance."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            settingsSection("Quit Behavior") {
                Toggle(
                    "Confirm before quitting Ghosthub",
                    isOn: Binding(
                        get: { store.confirmBeforeQuitting },
                        set: { store.setConfirmBeforeQuitting($0) }
                    )
                )

                Text(
                    "Ghosthub asks before quitting. Closing windows does not quit"
                        + " Ghosthub, and tmux sessions keep running either way."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keyboardDetail: some View {
        ApplicationShortcutsView()
    }

    private var worktreesDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("Sidebar Behavior") {
                Toggle(
                    "Hide the root checkout in the sidebar",
                    isOn: $draft.hideRootCheckout
                )
                Toggle(
                    "Show hidden worktrees by default",
                    isOn: $draft.showHiddenWorktreesByDefault
                )

                Text(
                    "Kwt remains authoritative for registered projects,"
                        + " worktrees, and tmux session names."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            settingsSection("Standalone Tmux Sessions") {
                Text("Hidden session patterns")
                    .font(.system(size: 13, weight: .semibold))

                TextEditor(text: hiddenTmuxSessionPatternsText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 96)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    )
                    .accessibilityLabel("Hidden tmux session patterns")

                Text(
                    "Enter one case-sensitive wildcard pattern per line."
                        + " Use * for any number of characters and ? for one."
                        + " Matching standalone sessions are hidden from the"
                        + " sidebar and command palette; kwt workspaces remain"
                        + " discoverable under their projects."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                configPathRow(
                    "Ghosthub stores these patterns in:",
                    path: store.appConfigFile.path
                )
            }

            settingsSection("Workspace Sessions") {
                Label(
                    "Kwt supplies each workspace’s exact tmux session name.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.secondary)

                Label(
                    "Tmux owns windows, panes, layout, history, and process lifetime.",
                    systemImage: "rectangle.split.3x1"
                )
                .foregroundStyle(.secondary)

                Label(
                    "Closing Ghosthub detaches; reopening reattaches locally or over SSH.",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .foregroundStyle(.secondary)
            }
        }
    }

    private var hiddenTmuxSessionPatternsText: Binding<String> {
        Binding(
            get: {
                draft.hiddenTmuxSessionPatterns.joined(separator: "\n")
            },
            set: { value in
                draft.hiddenTmuxSessionPatterns = value.components(
                    separatedBy: .newlines
                )
            }
        )
    }

    private var agentsDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("Agent Attention") {
                Toggle(
                    "Show macOS notifications when agents need attention",
                    isOn: $draft.showMacOSNotifications
                )

                settingRow("Attention sound") {
                    Picker(
                        "Attention sound",
                        selection: $draft.attentionSound
                    ) {
                        ForEach(
                            WorkspaceNotificationSound.allCases,
                            id: \.self
                        ) { sound in
                            Text(sound.title).tag(sound)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(!draft.showMacOSNotifications)
                }

                Text(
                    "Ghosthub uses this notification policy when a"
                        + " recognized agent session needs attention."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var privacyDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("Anonymous Usage Data") {
                Toggle(
                    "Share anonymous usage data",
                    isOn: Binding(
                        get: {
                            store.shareAnonymousUsageData
                        },
                        set: {
                            store.setShareAnonymousUsageData($0)
                        }
                    )
                )

                Text(
                    "Ghosthub sends at most one application-active"
                        + " event per day with a random installation ID,"
                        + " app version, and build number. It never sends"
                        + " repository, worktree, host, session, path,"
                        + " command, or terminal data."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appearanceDetail: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsSection("App Appearance") {
                settingRow("App appearance") {
                    Picker("App appearance", selection: $draft.interfaceAppearance) {
                        Text("Follow System").tag(AppearancePreference.system)
                        Text("Light").tag(AppearancePreference.light)
                        Text("Dark").tag(AppearancePreference.dark)
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
            }

            settingsSection("Tmux Theme") {
                settingRow("Theme") {
                    Picker("Theme", selection: $draft.terminalTheme) {
                        ForEach(TerminalTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }

                terminalThemePreview(theme: draft.terminalTheme)

                Toggle(
                    "Apply theme to shared tmux sessions",
                    isOn: $draft.appliesTerminalThemeToTmuxSessions
                )
                .accessibilityIdentifier(
                    "settings.apply-theme-to-tmux-sessions"
                )

                Text(
                    "Ghosthub applies the selected colors when it creates a new tmux session. Existing sessions keep their current appearance unless the shared-session override is enabled. Follow ghostty.conf uses the effective foreground and background resolved from Ghosthub's config, including the active light or dark theme. The override changes tmux window, status, and message colors for every attached client. Session > Apply Theme to Current Session, also available in the command palette, applies the current selection immediately without enabling the override."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            settingsSection("Terminal Font") {
                Toggle("Override font from ghostty.conf", isOn: $draft.usesCustomTerminalFont)

                if draft.usesCustomTerminalFont {
                    settingRow("Font family") {
                        Picker("Font family", selection: $draft.terminalFontFamily) {
                            ForEach(availableTerminalFontFamilies, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }

                    settingRow("Font size") {
                        Picker("Font size", selection: $draft.terminalFontSize) {
                            ForEach(availableTerminalFontSizes, id: \.self) { size in
                                Text(fontSizeLabel(size)).tag(size)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }

                Text(
                    "When font override is off, Ghosthub leaves font-family and font-size entirely to ghostty.conf. When it is on, the override lives in a Ghosthub-owned terminal appearance file."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            settingsSection("Cursor") {
                settingRow("Cursor style") {
                    Picker("Cursor style", selection: $draft.cursorStyle) {
                        Text("Block").tag(CursorStyle.block)
                        Text("Line").tag(CursorStyle.bar)
                        Text("Underline").tag(CursorStyle.underline)
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                Toggle(
                    "Let shell integration control cursor shape",
                    isOn: $draft.allowShellIntegrationToControlCursor
                )

                Text(
                    "Cursor shape can either follow Ghosthub's chosen cursor style or let shell integration change it dynamically."
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            settingsSection("Config Files") {
                configPathRow(
                    "Ghosthub reads base terminal config from:",
                    path: store.terminalConfigFile.path
                )
                configPathRow(
                    "Ghosthub writes built-in theme/font overrides to:",
                    path: store.terminalAppearanceConfigFile.path
                )
            }
        }
    }

    private func settingRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            control()
        }
    }

    private func configPathRow(
        _ label: String,
        path: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        path, forType: .string
                    )
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy path")
                .accessibilityLabel("Copy config path")
            }
        }
    }

    private func fontSizeLabel(_ size: Double) -> String {
        if size.rounded() == size {
            return "\(Int(size)) pt"
        }
        return "\(size.formatted(.number.precision(.fractionLength(1)))) pt"
    }

    @ViewBuilder
    private func terminalThemePreview(
        theme: TerminalTheme
    ) -> some View {
        if let spec = theme.spec {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(spec.background.swiftUIColor)
                    .overlay(
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(spec.foreground.swiftUIColor)
                                .frame(width: 18, height: 6)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(spec.emphasis.swiftUIColor)
                                .frame(width: 18, height: 6)
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(spec.cursorColor.swiftUIColor)
                                .frame(width: 4, height: 18)
                            if let selection = spec.selection {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(selection.swiftUIColor)
                                    .frame(width: 18, height: 12)
                            }
                        }
                        .padding(.horizontal, 12)
                    )
                    .frame(width: 120, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(theme.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(theme.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text(theme.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @discardableResult
    private func persist() -> SettingsPersistResult {
        let result = draft.persist(to: store)
        if result.shouldRefreshHosts {
            actions.refreshHosts()
        }
        if result.shouldReloadTerminalConfig {
            actions.reloadTerminalConfig()
        }
        return result
    }

}
