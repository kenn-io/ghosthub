import Combine
import GhosthubSettings
import SwiftUI

private struct PendingExeHostTrust: Identifiable {
    var account: ExeAccount
    var confirmation: SSHHostKeyConfirmation

    var id: String {
        "\(account.id):\(confirmation.fingerprint)"
    }
}

struct PendingExeAuthentication: Identifiable {
    var accountConfigKey: String
    var sshDestination: String
    var surfaceID = UUID()

    var id: UUID { surfaceID }

    init(
        account: ExeAccount,
        surfaceID: UUID = UUID()
    ) {
        accountConfigKey = account.configKey
        sshDestination = account.sshDestination
        self.surfaceID = surfaceID
    }

    func currentAccount(in accounts: [ExeAccount]) -> ExeAccount? {
        ExeAccountSanitizer.discoverableAccounts(accounts).first {
            $0.configKey == accountConfigKey
                && $0.sshDestination == sshDestination
                && $0.isEnabled
        }
    }
}

enum ExeAccountTrustAction {
    case review(SSHHostKeyConfirmation)
    case authenticate
    case probe
    case fail(HostProbeError)

    static func resolve(
        _ result: Result<SSHHostKeyReviewRequirement, HostProbeError>
    ) -> Self {
        switch result {
        case let .success(.confirmation(confirmation)):
            return .review(confirmation)
        case .success(.authenticationRequired):
            return .authenticate
        case .success(.none):
            return .probe
        case let .failure(error):
            return .fail(error)
        }
    }
}

enum ExeAccountConnectionAction {
    case authenticate
    case refresh
    case fail(String)

    static func resolve(_ result: ExeAccountConnectionProbeResult) -> Self {
        switch result {
        case .connected:
            return .refresh
        case .authenticationRequired:
            return .authenticate
        case let .failed(message):
            return .fail(message)
        }
    }
}

struct ExeAccountConnectionOperation: Equatable {
    var id: UUID
    var accounts: [ExeAccount]

    init(accounts: [ExeAccount], id: UUID = UUID()) {
        self.id = id
        self.accounts = ExeAccountSanitizer.discoverableAccounts(accounts)
            .filter(\.isEnabled)
    }

    func matches(
        _ current: ExeAccountConnectionOperation?,
        accounts currentAccounts: [ExeAccount]
    ) -> Bool {
        current?.id == id
            && accounts == ExeAccountSanitizer.discoverableAccounts(
                currentAccounts
            )
            .filter(\.isEnabled)
    }
}

enum ExeAccountConnectionRunResult {
    case cancelled
    case review(
        account: ExeAccount,
        confirmation: SSHHostKeyConfirmation,
        messages: [String: String]
    )
    case authenticate(account: ExeAccount, messages: [String: String])
    case refresh(accounts: [ExeAccount], messages: [String: String])
}

@MainActor
struct ExeAccountConnectionRunner {
    let pendingTrust:
        (ExeAccount) async -> Result<
            SSHHostKeyReviewRequirement,
            HostProbeError
        >
    let probe: (ExeAccount) async -> ExeAccountConnectionProbeResult

    func run(
        _ operation: ExeAccountConnectionOperation,
        isCurrent: () -> Bool
    ) async -> ExeAccountConnectionRunResult {
        var messages: [String: String] = [:]
        for account in operation.accounts {
            let trustResult = await pendingTrust(account)
            guard !Task.isCancelled, isCurrent() else {
                return .cancelled
            }
            switch ExeAccountTrustAction.resolve(trustResult) {
            case let .review(confirmation):
                return .review(
                    account: account,
                    confirmation: confirmation,
                    messages: messages
                )
            case .authenticate:
                return .authenticate(account: account, messages: messages)
            case let .fail(error):
                messages[account.id] = error.displayMessage
                continue
            case .probe:
                break
            }

            let probeResult = await probe(account)
            guard !Task.isCancelled, isCurrent() else {
                return .cancelled
            }
            switch ExeAccountConnectionAction.resolve(probeResult) {
            case .authenticate:
                return .authenticate(account: account, messages: messages)
            case .refresh:
                continue
            case let .fail(message):
                messages[account.id] = message
                continue
            }
        }
        guard !Task.isCancelled, isCurrent() else {
            return .cancelled
        }
        return .refresh(accounts: operation.accounts, messages: messages)
    }
}

struct ExeAccountsSettingsView: View {
    @Binding var accounts: [ExeAccount]
    let statusesPublisher:
        AnyPublisher<[String: ExeAccountStatus], Never>
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
    let probeConnection:
        (ExeAccount) async -> ExeAccountConnectionProbeResult
    let refresh: ([ExeAccount]) -> UUID?
    let cancelRefresh: (UUID) -> Void
    let invalidateRefresh: (UUID, [ExeAccount]) -> Void

    @State private var statuses: [String: ExeAccountStatus] = [:]
    @State private var messages: [String: String] = [:]
    @State private var pendingTrust: PendingExeHostTrust?
    @State private var pendingAuthentication: PendingExeAuthentication?
    @State private var authenticationSucceeded = false
    @State private var isTrusting = false
    @State private var connectionOperation: ExeAccountConnectionOperation?
    @State private var connectionTask: Task<Void, Never>?
    @State private var inventoryRefreshID: UUID?

    var body: some View {
        settingsSection("exe.dev") {
            Text(
                "Show your running exe.dev VMs in Ghosthub and connect to"
                    + " them over SSH. VM creation and lifecycle remain in"
                    + " exe.dev."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(accounts) { account in
                if let binding = accountBinding(account.id) {
                    accountRow(account, binding: binding)
                }
            }

            HStack(spacing: 8) {
                Button(
                    accounts.isEmpty ? "Add Account" : "Add Another Account",
                    action: addAccount
                )
                Link(
                    "Setup help",
                    destination: URL(string: "https://exe.dev/docs")!
                )
                .font(.system(size: 12))
                Spacer()
                Button("Connect and Discover VMs", action: connectAndRefresh)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasRefreshableAccount)
            }
        }
        .onReceive(statusesPublisher) { statuses = $0 }
        .onChange(of: accounts) { _, currentAccounts in
            cancelConnection()
            invalidateInventoryRefresh(currentAccounts: currentAccounts)
        }
        .onDisappear {
            cancelConnection()
            cancelInventoryRefresh()
        }
        .sheet(item: $pendingTrust) { pending in
            hostTrustSheet(pending)
        }
        .sheet(item: $pendingAuthentication) { pending in
            authenticationSheet(pending)
        }
    }

    private func accountRow(
        _ account: ExeAccount,
        binding: Binding<ExeAccount>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    "Account details",
                    systemImage: "person.crop.circle"
                )
                .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Enabled", isOn: binding.isEnabled)
                    .toggleStyle(.checkbox)
                Button("Remove", role: .destructive) {
                    removeAccount(account.id)
                }
                .help("Remove exe.dev account")
            }

            HStack(alignment: .top, spacing: 12) {
                accountField(
                    "Account name",
                    placeholder: "Personal",
                    text: binding.name
                )
                accountField(
                    "SSH destination",
                    placeholder: "exe.dev",
                    text: binding.sshDestination
                )
            }

            Text(
                "Each enabled account needs a unique SSH destination. Use"
                    + " exe.dev for one account and distinct Host aliases in"
                    + " your OpenSSH configuration for additional accounts."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            accountStatus(account)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.07))
        )
    }

    private func accountField(
        _ label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func accountStatus(_ account: ExeAccount) -> some View {
        if !account.isEnabled {
            Text("Disabled")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else if account.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            errorText("Enter an account name.")
        } else if account.sshDestination.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            errorText(
                accounts.filter(\.isEnabled).count > 1
                    ? "Enter a distinct OpenSSH Host alias for this account."
                    : "Enter an SSH destination."
            )
        } else if duplicateEnabledDestinations.contains(
            account.sshDestination.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        ) {
            errorText(
                "This destination is used by another enabled account."
                    + " Configure a distinct OpenSSH Host alias."
            )
        } else if let message = messages[account.id] {
            errorText(message)
        } else if let status = statuses[account.id] {
            switch status {
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Discovering VMs…")
                }
                .font(.system(size: 12))
            case let .loaded(totalVMs, runningVMs):
                Text(
                    "\(runningVMs) running of \(totalVMs) VM"
                        + (totalVMs == 1 ? "" : "s")
                )
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            case let .failed(message):
                errorText(message)
            }
        } else {
            Text("Not connected yet")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var hasRefreshableAccount: Bool {
        let enabled = accounts.filter(\.isEnabled)
        return !enabled.isEmpty
            && ExeAccountSanitizer.discoverableAccounts(enabled).count
            == enabled.count
    }

    private var duplicateEnabledDestinations: Set<String> {
        ExeAccountSanitizer.duplicateEnabledDestinations(accounts)
    }

    private func accountBinding(_ id: String) -> Binding<ExeAccount>? {
        guard let index = accounts.firstIndex(where: {
            $0.id == id
        }) else { return nil }
        return $accounts[index]
    }

    private func addAccount() {
        let existing = Set(accounts.map(\.configKey))
        var key = "exe-dev"
        var suffix = 2
        while existing.contains(key) {
            key = "exe-dev-\(suffix)"
            suffix += 1
        }
        accounts.append(ExeAccount(
            configKey: key,
            name: accounts.isEmpty ? "Personal" : "Account \(accounts.count + 1)",
            sshDestination: accounts.isEmpty ? "exe.dev" : ""
        ))
    }

    private func removeAccount(_ id: String) {
        accounts.removeAll { $0.id == id }
        messages.removeValue(forKey: id)
    }

    private func connectAndRefresh() {
        cancelConnection()
        messages = [:]
        let operation = ExeAccountConnectionOperation(accounts: accounts)
        guard !operation.accounts.isEmpty else { return }
        connectionOperation = operation
        let runner = ExeAccountConnectionRunner(
            pendingTrust: { account in
                await pendingSSHHostKeyConfirmation(controlHost(account))
            },
            probe: probeConnection
        )
        connectionTask = Task {
            let result = await runner.run(operation) {
                operation.matches(connectionOperation, accounts: accounts)
            }
            guard operation.matches(
                connectionOperation,
                accounts: accounts
            ) else { return }
            completeConnection(operation)
            switch result {
            case .cancelled:
                return
            case let .review(account, confirmation, operationMessages):
                messages = operationMessages
                pendingTrust = PendingExeHostTrust(
                    account: account,
                    confirmation: confirmation
                )
            case let .authenticate(account, operationMessages):
                messages = operationMessages
                beginAuthentication(account)
            case let .refresh(refreshAccounts, operationMessages):
                messages = operationMessages
                inventoryRefreshID = refresh(refreshAccounts)
            }
        }
    }

    private func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        connectionOperation = nil
    }

    private func cancelInventoryRefresh() {
        guard let inventoryRefreshID else { return }
        self.inventoryRefreshID = nil
        cancelRefresh(inventoryRefreshID)
    }

    private func invalidateInventoryRefresh(
        currentAccounts: [ExeAccount]
    ) {
        guard let inventoryRefreshID else { return }
        invalidateRefresh(inventoryRefreshID, currentAccounts)
    }

    private func completeConnection(
        _ operation: ExeAccountConnectionOperation
    ) {
        guard connectionOperation?.id == operation.id else { return }
        connectionTask = nil
        connectionOperation = nil
    }

    private func authenticationSheet(
        _ pending: PendingExeAuthentication
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("SSH Authentication", systemImage: "key")
                .font(.system(size: 20, weight: .semibold))

            Text(
                "Enter the response requested by OpenSSH. Ghosthub keeps it"
                    + " only long enough to complete this connection."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if authenticationSucceeded {
                Label(
                    "Connected successfully",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
                Text("Continue to discover this account's VMs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if let account = pending.currentAccount(in: accounts),
                      let authentication = sshAuthenticationView(
                          pending.surfaceID,
                          controlHost(account)
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
                if authenticationSucceeded {
                    Button("Continue") {
                        pendingAuthentication = nil
                        authenticationSucceeded = false
                        connectAndRefresh()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) {
                        cancelSSHAuthentication(pending.surfaceID)
                        pendingAuthentication = nil
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .task(id: pending.id) {
            await monitorAuthentication(pending)
        }
        .interactiveDismissDisabled()
    }

    private func beginAuthentication(_ account: ExeAccount) {
        authenticationSucceeded = false
        pendingAuthentication = PendingExeAuthentication(
            account: account
        )
    }

    private func monitorAuthentication(
        _ pending: PendingExeAuthentication
    ) async {
        while !Task.isCancelled,
              pendingAuthentication?.id == pending.id {
            guard let account = pending.currentAccount(in: accounts) else {
                cancelSSHAuthentication(pending.surfaceID)
                pendingAuthentication = nil
                return
            }
            let readiness = await isSSHAuthenticationReady(
                controlHost(account)
            )
            guard !Task.isCancelled,
                  pendingAuthentication?.id == pending.id
            else { return }
            switch readiness {
            case .pending:
                break
            case .reviewRequired:
                cancelSSHAuthentication(pending.surfaceID)
                pendingAuthentication = nil
                connectAndRefresh()
                return
            case .connected:
                cancelSSHAuthentication(pending.surfaceID)
                authenticationSucceeded = true
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func controlHost(_ account: ExeAccount) -> SSHHost {
        SSHHost(
            configKey: "exe-control.\(account.configKey)",
            name: account.name,
            platform: .linux,
            sshDestination: account.sshDestination
        )
    }

    private func hostTrustSheet(
        _ pending: PendingExeHostTrust
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Verify exe.dev", systemImage: "lock.shield")
                .font(.system(size: 20, weight: .semibold))
            SSHHostKeyConfirmationDetails(
                confirmation: pending.confirmation
            )
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    pendingTrust = nil
                }
                .disabled(isTrusting)
                Button(isTrusting ? "Trusting…" : "Trust and Refresh") {
                    Task { await trust(pending) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isTrusting)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isTrusting)
    }

    private func trust(_ pending: PendingExeHostTrust) async {
        isTrusting = true
        defer { isTrusting = false }
        let result = await trustSSHHostKey(
            pending.confirmation,
            controlHost(pending.account)
        )
        switch result {
        case let .success(nextConfirmation):
            if let nextConfirmation {
                pendingTrust = PendingExeHostTrust(
                    account: pending.account,
                    confirmation: nextConfirmation
                )
            } else {
                pendingTrust = nil
                connectAndRefresh()
            }
        case let .failure(error):
            messages[pending.account.id] = error.displayMessage
            pendingTrust = nil
        }
    }
}
