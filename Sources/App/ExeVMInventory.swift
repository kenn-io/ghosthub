import GhosthubTransport
@preconcurrency import Combine
import Foundation
import GhosthubSettings
import GhosthubTmux
import GhosthubWorkspace

private struct ExeVMListResponse: Decodable {
    var vms: [ExeVMRecord]
}

enum ExeVMInventoryError: Error, Equatable, LocalizedError {
    case invalidDestination
    case commandFailed(destination: String, status: Int32, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "Enter a valid exe.dev SSH destination."
        case let .commandFailed(destination, _, message):
            let detail = message.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if detail.isEmpty {
                return "Could not query exe.dev through \(destination)."
            }
            return "Could not query exe.dev through \(destination): \(detail)"
        case .invalidResponse:
            return "exe.dev returned an unsupported VM inventory response."
        }
    }
}

struct ExeVMClient: Sendable {
    typealias Runner = @Sendable (SSHHostInfo, String, String) -> (
        status: Int32,
        stdout: String,
        stderr: String
    )

    private let runner: Runner

    init(runner: @escaping Runner = Self.runListCommand) {
        self.runner = runner
    }

    func listVMs(for account: ExeAccount) throws -> [ExeVMRecord] {
        guard let host = CommandHostResolver.parseSSHDestination(
            account.sshDestination
        ) else {
            throw ExeVMInventoryError.invalidDestination
        }
        let nonce = UUID().uuidString
        let startMarker = "GHOSTHUB_EXE_JSON_START_\(nonce)"
        let endMarker = "GHOSTHUB_EXE_JSON_END_\(nonce)"
        let result = runner(host, startMarker, endMarker)
        guard result.status == 0 else {
            throw ExeVMInventoryError.commandFailed(
                destination: account.sshDestination,
                status: result.status,
                message: result.stderr
            )
        }
        guard let output = Self.framedOutput(
            result.stdout,
            startMarker: startMarker,
            endMarker: endMarker
        ),
            let data = output.data(using: .utf8),
            let response = try? JSONDecoder().decode(
                ExeVMListResponse.self,
                from: data
            )
        else {
            throw ExeVMInventoryError.invalidResponse
        }
        return response.vms
    }

    func connectionProbe(
        for account: ExeAccount
    ) -> ExeAccountConnectionProbeResult {
        do {
            return .connected(try listVMs(for: account))
        } catch let error as ExeVMInventoryError {
            if case let .commandFailed(_, status, message) = error,
               SSHConnectionFailure.diagnostic(
                   status: status,
                   output: message
               ).code == .sshAuthenticationFailed {
                return .authenticationRequired
            }
            return .failed(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func framedOutput(
        _ output: String,
        startMarker: String,
        endMarker: String
    ) -> String? {
        let lines = output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let start = lines.firstIndex(of: startMarker),
              let end = lines[lines.index(after: start)...]
              .firstIndex(of: endMarker),
              start < end
        else { return nil }
        return lines[lines.index(after: start) ..< end]
            .joined(separator: "\n")
    }

    private static func runListCommand(
        host: SSHHostInfo,
        startMarker: String,
        endMarker: String
    ) -> (status: Int32, stdout: String, stderr: String) {
        var arguments = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
        ]
        arguments.append(contentsOf:
            SSHCommandArguments.noninteractive(for: host)
        )
        if let port = host.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        let destination = host.user.map {
            "\($0)@\(host.hostname)"
        } ?? host.hostname
        arguments.append(contentsOf: [
            "--", destination, "ls", "--json",
        ])
        let sshCommand = (["/usr/bin/ssh"] + arguments)
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
        let command = """
        printf '\\n%s\\n' \(shellQuotedCommandArgument(startMarker))
        \(sshCommand)
        ghosthub_exe_status=$?
        printf '\\n%s\\n' \(shellQuotedCommandArgument(endMarker))
        exit "$ghosthub_exe_status"
        """
        let output = AccountCommandRunner.runProcess(
            executable: AccountCommandRunner.loginShell(),
            arguments: ["-lc", accountShellCommand(command)],
            timeout: 15
        )
        return (output.status, output.stdout, output.stderr)
    }
}

struct ExeConfiguredHost: Equatable, Sendable {
    var sshHost: SSHHost
    var metadata: ExeVMMetadata
}

private struct ExeAccountHostCache {
    var sshDestination: String
    var hosts: [ExeConfiguredHost]
}

private struct ExeVMInventoryRefreshState {
    var id: UUID
    var accountDestinations: [String: String]
    var accountNames: [String: String]
    var persistedAccountDestinations: [String: String]
    var persistedAccountNames: [String: String]
    var visibleAccountDestinations: [String: String]
    var visibleAccountNames: [String: String]
    var previousHostsByAccount: [String: ExeAccountHostCache]
    var previousStatuses: [String: ExeAccountStatus]
    var completedAccountKeys: Set<String> = []
    var isComplete = false
}

@MainActor
final class ExeVMInventoryStore: ObservableObject {
    static let shared = ExeVMInventoryStore()

    @Published private(set) var hosts: [ExeConfiguredHost] = []
    @Published private(set) var statuses: [String: ExeAccountStatus] = [:]

    private let client: ExeVMClient
    private var hostsByAccount: [String: ExeAccountHostCache] = [:]
    private var statusesByAccount: [String: ExeAccountStatus] = [:]
    private var settingsCancellable: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var refreshState: ExeVMInventoryRefreshState?
    private var isPublishingInventory = false
    private var needsInventoryPublish = false

    init(client: ExeVMClient = ExeVMClient()) {
        self.client = client
    }

    func start(settingsStore: SettingsStore = .shared) {
        guard settingsCancellable == nil else { return }
        settingsCancellable = settingsStore.$exeAccounts
            .removeDuplicates()
            .sink { [weak self] accounts in
                self?.refresh(accounts: accounts)
            }
    }

    @discardableResult
    func refresh(
        accounts: [ExeAccount] = SettingsStore.shared.exeAccounts
    ) -> UUID {
        refresh(accounts: accounts, persistedAccounts: accounts)
    }

    @discardableResult
    func refresh(
        accounts: [ExeAccount],
        persistedAccounts: [ExeAccount],
        prefetchedVMs: [String: [ExeVMRecord]] = [:]
    ) -> UUID {
        let enabled = ExeAccountSanitizer.discoverableAccounts(accounts)
            .filter(\.isEnabled)
        var enabledDestinations: [String: String] = [:]
        var enabledNames: [String: String] = [:]
        for account in enabled {
            enabledDestinations[account.configKey] = account.sshDestination
            enabledNames[account.configKey] = account.name
        }
        let persistedDestinations = Self.enabledDestinations(
            in: ExeAccountSanitizer.discoverableAccounts(persistedAccounts)
        )
        let persistedNames = Self.enabledAccountNames(
            in: ExeAccountSanitizer.discoverableAccounts(persistedAccounts)
        )
        let previousState = refreshState
        refreshState = nil
        refreshTask?.cancel()
        refreshTask = nil
        if let previousState {
            reconcileInventory(
                retaining: persistedAccounts,
                after: previousState
            )
        }
        let previousHostsByAccount = hostsByAccount
        let previousStatuses = statusesByAccount
        let refreshID = UUID()
        hostsByAccount = hostsByAccount.filter {
            enabledDestinations[$0.key] == $0.value.sshDestination
                || persistedDestinations[$0.key] == $0.value.sshDestination
        }
        for (configKey, name) in enabledNames {
            guard var cache = hostsByAccount[configKey] else { continue }
            for index in cache.hosts.indices {
                cache.hosts[index].metadata.accountName = name
            }
            hostsByAccount[configKey] = cache
        }
        let retainedKeys = Set(enabledDestinations.keys)
            .union(persistedDestinations.keys)
        statusesByAccount = statusesByAccount.filter { configKey, _ in
            retainedKeys.contains(configKey)
        }
        var visibleDestinations = persistedDestinations
        var visibleNames = persistedNames
        for (configKey, destination) in enabledDestinations {
            visibleDestinations[configKey] = destination
        }
        for (configKey, name) in enabledNames {
            visibleNames[configKey] = name
        }
        refreshState = ExeVMInventoryRefreshState(
            id: refreshID,
            accountDestinations: enabledDestinations,
            accountNames: enabledNames,
            persistedAccountDestinations: persistedDestinations,
            persistedAccountNames: persistedNames,
            visibleAccountDestinations: visibleDestinations,
            visibleAccountNames: visibleNames,
            previousHostsByAccount: previousHostsByAccount,
            previousStatuses: previousStatuses
        )

        guard !enabled.isEmpty else {
            refreshState?.isComplete = true
            publishInventory()
            return refreshID
        }
        var accountsToQuery: [ExeAccount] = []
        for account in enabled {
            if let vms = prefetchedVMs[account.configKey] {
                applyInventory(
                    vms,
                    for: account,
                    accountName: enabledNames[account.configKey] ?? account.name
                )
                refreshState?.completedAccountKeys.insert(account.configKey)
            } else {
                statusesByAccount[account.configKey] = .loading
                accountsToQuery.append(account)
            }
        }
        publishInventory()
        guard !accountsToQuery.isEmpty else {
            refreshState?.isComplete = true
            return refreshID
        }
        let client = client
        refreshTask = Task { [weak self] in
            await withTaskGroup(
                of: (ExeAccount, Result<[ExeVMRecord], Error>).self
            ) { group in
                for account in accountsToQuery {
                    group.addTask {
                        do {
                            return (
                                account,
                                .success(try client.listVMs(for: account))
                            )
                        } catch {
                            return (account, .failure(error))
                        }
                    }
                }
                for await (account, result) in group {
                    guard let self,
                          !Task.isCancelled,
                          self.refreshState?.id == refreshID
                    else { return }
                    guard let state = self.refreshState,
                          state.accountDestinations[account.configKey]
                          == account.sshDestination
                    else { continue }
                    let accountName = state.accountNames[account.configKey]
                        ?? account.name
                    switch result {
                    case let .success(vms):
                        self.applyInventory(
                            vms,
                            for: account,
                            accountName: accountName
                        )
                        self.refreshState?.completedAccountKeys.insert(
                            account.configKey
                        )
                    case let .failure(error):
                        self.refreshState?.completedAccountKeys.insert(
                            account.configKey
                        )
                        self.statusesByAccount[account.configKey] = .failed(
                            error.localizedDescription
                        )
                    }
                    self.publishInventory()
                }
            }
            guard let self,
                  !Task.isCancelled,
                  refreshState?.id == refreshID
            else { return }
            refreshState?.isComplete = true
            refreshTask = nil
        }
        return refreshID
    }

    func cancelRefresh(
        _ refreshID: UUID,
        retaining accounts: [ExeAccount]
    ) {
        guard let state = refreshState,
              state.id == refreshID
        else { return }
        refreshState = nil
        if !state.isComplete {
            refreshTask?.cancel()
        }
        refreshTask = nil
        reconcileInventory(retaining: accounts, after: state)
        publishInventory()
    }

    func invalidateRefresh(
        _ refreshID: UUID,
        currentAccounts: [ExeAccount]
    ) {
        guard let state = refreshState,
              state.id == refreshID
        else { return }
        let previousAccounts = state.accountDestinations.map {
            ExeAccount(
                configKey: $0.key,
                name: state.accountNames[$0.key] ?? $0.key,
                sshDestination: $0.value
            )
        }
        let resolvedAccounts = ExeAccountSanitizer.accountsForPersistence(
            currentAccounts,
            previous: previousAccounts
        )
        let currentDestinations = Self.enabledDestinations(
            in: resolvedAccounts
        )
        let retainedDestinations = state.accountDestinations.filter {
            currentDestinations[$0.key] == $0.value
        }
        var retainedNames = state.accountNames.filter {
            retainedDestinations[$0.key] != nil
        }
        for (configKey, name) in Self.enabledAccountNames(
            in: resolvedAccounts
        ) where retainedDestinations[configKey] != nil {
            retainedNames[configKey] = name
        }
        var visibleDestinations = state.persistedAccountDestinations
        for (configKey, destination) in retainedDestinations {
            visibleDestinations[configKey] = destination
        }
        var visibleNames = state.persistedAccountNames.filter {
            visibleDestinations[$0.key] != nil
        }
        for (configKey, name) in retainedNames {
            visibleNames[configKey] = name
        }
        refreshState?.visibleAccountDestinations = visibleDestinations
        refreshState?.visibleAccountNames = visibleNames
        publishInventory()
    }

    private static func enabledDestinations(
        in accounts: [ExeAccount]
    ) -> [String: String] {
        var destinations: [String: String] = [:]
        for account in accounts where account.isEnabled {
            let configKey = account.configKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let destination = account.sshDestination.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !configKey.isEmpty,
                  !destination.isEmpty,
                  destinations[configKey] == nil
            else { continue }
            destinations[configKey] = destination
        }
        return destinations
    }

    private static func enabledAccountNames(
        in accounts: [ExeAccount]
    ) -> [String: String] {
        var names: [String: String] = [:]
        for account in accounts where account.isEnabled {
            let configKey = account.configKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let name = account.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !configKey.isEmpty,
                  !name.isEmpty,
                  names[configKey] == nil
            else { continue }
            names[configKey] = name
        }
        return names
    }

    private func reconcileInventory(
        retaining accounts: [ExeAccount],
        after state: ExeVMInventoryRefreshState
    ) {
        let retainedAccounts = ExeAccountSanitizer
            .discoverableAccounts(accounts)
            .filter(\.isEnabled)
        var retainedHosts: [String: ExeAccountHostCache] = [:]
        var retainedStatuses: [String: ExeAccountStatus] = [:]

        for account in retainedAccounts {
            let configKey = account.configKey
            let destination = account.sshDestination
            let currentMatches = state.accountDestinations[configKey]
                == destination
            let cache: ExeAccountHostCache? = if currentMatches,
                                                 let current = hostsByAccount[configKey],
                                                 current.sshDestination == destination {
                current
            } else if let previous = state
                .previousHostsByAccount[configKey],
                previous.sshDestination == destination {
                previous
            } else {
                nil
            }
            if var cache {
                for index in cache.hosts.indices {
                    cache.hosts[index].metadata.accountName = account.name
                }
                retainedHosts[configKey] = cache
            }

            if currentMatches,
               state.completedAccountKeys.contains(configKey),
               let status = statusesByAccount[configKey] {
                retainedStatuses[configKey] = status
            } else if let status = state.previousStatuses[configKey] {
                retainedStatuses[configKey] = status
            }
        }
        hostsByAccount = retainedHosts
        statusesByAccount = retainedStatuses
    }

    private func publishInventory() {
        guard !isPublishingInventory else {
            needsInventoryPublish = true
            return
        }
        isPublishingInventory = true
        repeat {
            needsInventoryPublish = false
            if let state = refreshState {
                hosts = state.visibleAccountDestinations.keys.sorted().flatMap {
                    configKey -> [ExeConfiguredHost] in
                    guard let destination = state
                        .visibleAccountDestinations[configKey]
                    else { return [] }
                    let cache: ExeAccountHostCache? = if hostsByAccount[
                        configKey
                    ]?.sshDestination == destination {
                        hostsByAccount[configKey]
                    } else if state.previousHostsByAccount[configKey]?
                        .sshDestination == destination {
                        state.previousHostsByAccount[configKey]
                    } else {
                        nil
                    }
                    guard var visibleHosts = cache?.hosts else { return [] }
                    if let accountName = state.visibleAccountNames[configKey] {
                        for index in visibleHosts.indices {
                            visibleHosts[index].metadata.accountName = accountName
                        }
                    }
                    return visibleHosts
                }
                var visibleStatuses: [String: ExeAccountStatus] = [:]
                for (configKey, destination) in state
                    .visibleAccountDestinations {
                    if state.accountDestinations[configKey] == destination,
                       let status = statusesByAccount[configKey] {
                        visibleStatuses[configKey] = status
                    } else if let status = state.previousStatuses[configKey] {
                        visibleStatuses[configKey] = status
                    }
                }
                statuses = visibleStatuses
            } else {
                hosts = hostsByAccount.keys.sorted().flatMap {
                    hostsByAccount[$0]?.hosts ?? []
                }
                statuses = statusesByAccount
            }
        } while needsInventoryPublish
        isPublishingInventory = false
    }

    private func applyInventory(
        _ vms: [ExeVMRecord],
        for account: ExeAccount,
        accountName: String
    ) {
        let running = vms.filter(\.isRunning)
        hostsByAccount[account.configKey] = ExeAccountHostCache(
            sshDestination: account.sshDestination,
            hosts: running.map {
                Self.configuredHost(
                    $0,
                    account: account,
                    accountName: accountName
                )
            }
        )
        statusesByAccount[account.configKey] = .loaded(
            totalVMs: vms.count,
            runningVMs: running.count
        )
    }

    private static func configuredHost(
        _ vm: ExeVMRecord,
        account: ExeAccount,
        accountName: String
    ) -> ExeConfiguredHost {
        let configKey = "exe-dev.\(account.configKey).\(vm.vmName)"
        return ExeConfiguredHost(
            sshHost: SSHHost(
                configKey: configKey,
                name: vm.vmName,
                platform: .linux,
                sshDestination: vm.sshDestination
            ),
            metadata: ExeVMMetadata(
                accountConfigKey: account.configKey,
                accountName: accountName,
                vmName: vm.vmName,
                region: vm.region,
                regionDisplayName: vm.regionDisplayName,
                httpsURL: vm.httpsURL
            )
        )
    }
}
