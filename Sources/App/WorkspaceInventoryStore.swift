@preconcurrency import Combine
import AppKit
import Foundation
import GhosthubSettings
import GhosthubTransport

@MainActor
final class WorkspaceInventoryStore: ObservableObject {
    static let shared = WorkspaceInventoryStore()

    typealias KwtLoader = @Sendable (
        CommandHost
    ) async throws -> KwtHostInventory
    typealias KwtProvisioner = @Sendable (SSHHost) async throws -> Void
    typealias TmuxLoader = @Sendable (
        CommandHost
    ) async -> Result<[DiscoveredTmuxSession], TmuxBinaryError>
    typealias Sleep = @Sendable (Duration) async throws -> Void

    struct HostRegistration: Equatable, Sendable {
        let hostID: UUID
        let commandHost: CommandHost
        let provisioningHost: SSHHost?
    }

    enum KwtLoadState {
        case idle
        case loading
        case loaded
        case failed(any Error)
        case provisioningFailed
    }

    enum TmuxLoadState: Sendable {
        case idle
        case loading
        case loaded
        case failed(TmuxBinaryError)
    }

    struct KwtEntry {
        var inventory: KwtHostInventory?
        var inventoryRevision: UInt64
        var observationRevision: UInt64
        var state: KwtLoadState
        var isFresh: Bool

        static let empty = KwtEntry(
            inventory: nil,
            inventoryRevision: 0,
            observationRevision: 0,
            state: .idle,
            isFresh: false
        )
    }

    struct TmuxEntry: Sendable {
        var sessions: [DiscoveredTmuxSession]?
        var inventoryRevision: UInt64
        var observationRevision: UInt64
        var state: TmuxLoadState
        var isFresh: Bool

        static let empty = TmuxEntry(
            sessions: nil,
            inventoryRevision: 0,
            observationRevision: 0,
            state: .idle,
            isFresh: false
        )
    }

    struct Snapshot {
        var kwtByHost: [CommandHost: KwtEntry] = [:]
        var tmuxByHost: [CommandHost: TmuxEntry] = [:]
    }

    /// A removed project. Two non-empty repository identities compare by
    /// identity; when either side is legacy-empty, only the path recorded
    /// at removal time identifies the project.
    struct ProjectRemovalTombstone: Hashable, Sendable {
        let repository: String
        let path: String?

        func matches(_ record: KwtProjectRecord) -> Bool {
            if !repository.isEmpty, !record.repository.isEmpty {
                return record.repository == repository
            }
            guard let path else { return false }
            return record.path == path
        }
    }

    /// Identifies the mutation behind an authoritative KWT publication. The
    /// epoch is captured right after the mutation scope is acquired, so a
    /// result that predates a later mutation on the same host is rejected.
    struct MutationPublication: Equatable, Sendable {
        let hostID: UUID
        let host: CommandHost
        let epoch: UInt64
    }

    @Published private(set) var snapshot = Snapshot()

    private struct Subscriber {
        var registrations: [HostRegistration]
        var wantsKwt: Bool
        var wantsTmux: Bool
    }

    private let refreshInterval: Duration
    private let kwtLoader: KwtLoader
    private let kwtProvisioner: KwtProvisioner
    private let tmuxLoader: TmuxLoader
    private let sleep: Sleep
    private let mutationCoordinator: WorktreeMutationCoordinator
    private var mutationCancellable: AnyCancellable?
    private var appDidBecomeActiveCancellable: AnyCancellable?
    private var appDidResignActiveCancellable: AnyCancellable?
    private var subscribers: [UUID: Subscriber] = [:]
    private var kwtTasks: [CommandHost: Task<Void, Never>] = [:]
    private var tmuxTasks: [CommandHost: Task<Void, Never>] = [:]
    private var kwtGenerations: [CommandHost: UInt64] = [:]
    private var tmuxGenerations: [CommandHost: UInt64] = [:]
    private var fenceGenerationsByHostID: [UUID: UInt64] = [:]
    private var kwtMutationEpochsByHost: [CommandHost: UInt64] = [:]
    private var satisfiedFenceGenerationsByHostID: [UUID: UInt64] = [:]
    private var kwtRemovalTombstonesByHost:
        [CommandHost: [String: Set<KwtWorktreeIdentity>]] = [:]
    private var kwtProjectRemovalTombstonesByHost:
        [CommandHost: Set<ProjectRemovalTombstone>] = [:]
    private var revision: UInt64 = 0
    private var isApplicationActive = true
    private var cadenceTask: Task<Void, Never>?

    init(
        refreshInterval: Duration = .seconds(30),
        kwtLoader: @escaping KwtLoader = {
            try await KwtInventoryService().load(from: $0)
        },
        kwtProvisioner: @escaping KwtProvisioner = {
            try await KwtRemoteProvisioningCoordinator.shared
                .ensureInstalled(on: $0)
        },
        tmuxLoader: @escaping TmuxLoader = {
            await WorkspaceInventoryStore.discoverTmux(on: $0)
        },
        sleep: @escaping Sleep = {
            try await Task.sleep(for: $0)
        },
        mutationCoordinator: WorktreeMutationCoordinator = .shared
    ) {
        self.refreshInterval = refreshInterval
        self.kwtLoader = kwtLoader
        self.kwtProvisioner = kwtProvisioner
        self.tmuxLoader = tmuxLoader
        self.sleep = sleep
        self.mutationCoordinator = mutationCoordinator
        mutationCancellable = mutationCoordinator.events.sink {
            [weak self] event in
            self?.mutationEvent(event)
        }
    }

    func updateSubscriber(
        id: UUID,
        registrations: [HostRegistration],
        wantsKwt: Bool,
        wantsTmux: Bool
    ) {
        let previousKwtHosts = subscribedKwtHosts()
        let previousTmuxHosts = subscribedTmuxHosts()
        subscribers[id] = Subscriber(
            registrations: registrations,
            wantsKwt: wantsKwt,
            wantsTmux: wantsTmux
        )
        let currentKwtHosts = subscribedKwtHosts()
        let currentTmuxHosts = subscribedTmuxHosts()
        invalidateKwtHosts(previousKwtHosts.subtracting(currentKwtHosts))
        invalidateTmuxHosts(previousTmuxHosts.subtracting(currentTmuxHosts))

        if isApplicationActive, wantsKwt {
            for host in Set(registrations.map(\.commandHost))
                where needsInitialKwtLoad(host) {
                requestKwt(host)
            }
        }
        if isApplicationActive, wantsTmux {
            for host in Set(registrations.map(\.commandHost))
                where needsInitialTmuxLoad(host) {
                requestTmux(host)
            }
        }
        reconcileCadence()
    }

    func removeSubscriber(id: UUID) {
        let previousKwtHosts = subscribedKwtHosts()
        let previousTmuxHosts = subscribedTmuxHosts()
        subscribers.removeValue(forKey: id)
        invalidateKwtHosts(
            previousKwtHosts.subtracting(subscribedKwtHosts())
        )
        invalidateTmuxHosts(
            previousTmuxHosts.subtracting(subscribedTmuxHosts())
        )
        reconcileCadence()
    }

    func refreshKwt(for subscriberID: UUID) {
        guard let subscriber = subscribers[subscriberID],
              subscriber.wantsKwt else { return }
        for host in Set(subscriber.registrations.map(\.commandHost)) {
            invalidateKwtHosts([host])
            requestKwt(host)
        }
    }

    func refreshTmux(for subscriberID: UUID) {
        guard let subscriber = subscribers[subscriberID],
              subscriber.wantsTmux else { return }
        for host in Set(subscriber.registrations.map(\.commandHost)) {
            invalidateTmuxHosts([host])
            requestTmux(host)
        }
    }

    func refreshAll(for subscriberID: UUID) {
        refreshKwt(for: subscriberID)
        refreshTmux(for: subscriberID)
    }

    func kwtMutationEpoch(on host: CommandHost) -> UInt64 {
        kwtMutationEpochsByHost[host, default: 0]
    }

    /// Removal tombstones still active for a host. Scenes apply them to
    /// inventory they load themselves so a raw result cannot bring back a
    /// removed row before a fresh shared load confirms it is gone.
    func removalTombstones(
        on host: CommandHost
    ) -> [String: Set<KwtWorktreeIdentity>] {
        kwtRemovalTombstonesByHost[host] ?? [:]
    }

    func projectRemovalTombstones(
        on host: CommandHost
    ) -> Set<ProjectRemovalTombstone> {
        kwtProjectRemovalTombstonesByHost[host] ?? []
    }

    func publishKwtInventory(
        _ inventory: KwtHostInventory,
        on host: CommandHost,
        excludingWorktrees: [String: Set<KwtWorktreeIdentity>] = [:],
        mutation: MutationPublication?,
        recordsSuccessfulLoad: Bool = true
    ) {
        if let mutation,
           mutation.host != host
           || kwtMutationEpochsByHost[host, default: 0] != mutation.epoch {
            return
        }
        kwtGenerations[host, default: 0] &+= 1
        kwtTasks.removeValue(forKey: host)?.cancel()
        if recordsSuccessfulLoad,
           Self.isAuthoritative(inventory),
           let mutation,
           isSoleActiveMutation(
               hostID: mutation.hostID,
               on: host
           ) {
            satisfiedFenceGenerationsByHostID[mutation.hostID] =
                fenceGenerationsByHostID[mutation.hostID, default: 0]
        }
        recordKwtSuccess(
            inventory,
            host: host,
            excludingWorktrees: excludingWorktrees,
            recordsSuccessfulLoad: recordsSuccessfulLoad
        )
    }

    /// The current tmux refresh epoch for a host. A scene-local probe captures
    /// it before discovery and passes it back to `publishTmuxSessions`, which
    /// drops the publication when a newer shared refresh has started since.
    func tmuxRefreshEpoch(on host: CommandHost) -> UInt64 {
        tmuxGenerations[host, default: 0]
    }

    func publishTmuxSessions(
        _ sessions: [DiscoveredTmuxSession],
        on host: CommandHost,
        epoch: UInt64
    ) {
        guard tmuxGenerations[host, default: 0] == epoch else { return }
        tmuxGenerations[host, default: 0] &+= 1
        tmuxTasks.removeValue(forKey: host)?.cancel()
        recordTmuxSuccess(sessions, host: host)
    }

    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else { return }
        isApplicationActive = isActive
        cadenceTask?.cancel()
        cadenceTask = nil
        guard isActive else { return }
        let kwtHosts = subscribedKwtHosts()
        let tmuxHosts = subscribedTmuxHosts()
        invalidateKwtHosts(kwtHosts)
        invalidateTmuxHosts(tmuxHosts)
        for host in kwtHosts {
            requestKwt(host)
        }
        for host in tmuxHosts {
            requestTmux(host)
        }
        reconcileCadence()
    }

    func startApplicationActivityMonitoring(
        center: NotificationCenter = .default,
        initialIsActive: Bool = NSApplication.shared.isActive
    ) {
        guard appDidBecomeActiveCancellable == nil,
              appDidResignActiveCancellable == nil else { return }
        setApplicationActive(initialIsActive)
        appDidBecomeActiveCancellable = center.publisher(
            for: NSApplication.didBecomeActiveNotification
        ).sink { [weak self] _ in
            self?.setApplicationActive(true)
        }
        appDidResignActiveCancellable = center.publisher(
            for: NSApplication.didResignActiveNotification
        ).sink { [weak self] _ in
            self?.setApplicationActive(false)
        }
    }

    private func subscribedKwtHosts() -> Set<CommandHost> {
        Set(subscribers.values.filter(\.wantsKwt).flatMap {
            $0.registrations.map(\.commandHost)
        })
    }

    private func subscribedTmuxHosts() -> Set<CommandHost> {
        Set(subscribers.values.filter(\.wantsTmux).flatMap {
            $0.registrations.map(\.commandHost)
        })
    }

    private func needsInitialKwtLoad(_ host: CommandHost) -> Bool {
        let hostIDs = Set(registrations(for: host).map(\.hostID))
        if mutationCoordinator.quarantinedProjectRemovals.keys.contains(
            where: { hostIDs.contains($0.hostID) }
        ) {
            return true
        }
        guard let entry = snapshot.kwtByHost[host] else { return true }
        if case .idle = entry.state {
            return true
        }
        return false
    }

    private func needsInitialTmuxLoad(_ host: CommandHost) -> Bool {
        guard let entry = snapshot.tmuxByHost[host] else { return true }
        if case .idle = entry.state {
            return true
        }
        return false
    }

    private func requestKwt(_ host: CommandHost) {
        guard kwtTasks[host] == nil, !isKwtFenced(host) else { return }
        let generation = kwtGenerations[host, default: 0]
        let provisioningHost = provisioningHost(for: host)
        var entry = snapshot.kwtByHost[host] ?? .empty
        entry.state = .loading
        entry.isFresh = false
        snapshot.kwtByHost[host] = entry
        let loader = kwtLoader
        let provisioner = kwtProvisioner
        kwtTasks[host] = Task { [weak self] in
            if let provisioningHost {
                do {
                    try await Self.runDetached {
                        try await provisioner(provisioningHost)
                    }
                } catch {
                    guard let self, !Task.isCancelled,
                          kwtGenerations[host, default: 0]
                          == generation else { return }
                    recordKwtProvisioningFailure(host: host)
                    kwtTasks[host] = nil
                    return
                }
            }
            do {
                let inventory = try await Self.runDetached {
                    try await loader(host)
                }
                guard let self, !Task.isCancelled,
                      kwtGenerations[host, default: 0] == generation
                else { return }
                recordKwtSuccess(inventory, host: host)
                kwtTasks[host] = nil
            } catch is CancellationError {
                guard let self,
                      kwtGenerations[host, default: 0] == generation
                else { return }
                kwtTasks[host] = nil
            } catch {
                guard let self, !Task.isCancelled,
                      kwtGenerations[host, default: 0] == generation
                else { return }
                recordKwtFailure(error, host: host)
                kwtTasks[host] = nil
            }
        }
    }

    private func requestTmux(_ host: CommandHost) {
        guard tmuxTasks[host] == nil else { return }
        tmuxGenerations[host, default: 0] &+= 1
        let generation = tmuxGenerations[host, default: 0]
        var entry = snapshot.tmuxByHost[host] ?? .empty
        entry.state = .loading
        snapshot.tmuxByHost[host] = entry
        let loader = tmuxLoader
        tmuxTasks[host] = Task { [weak self] in
            let result = await Self.runDetached {
                await loader(host)
            }
            guard let self, !Task.isCancelled,
                  tmuxGenerations[host, default: 0] == generation
            else { return }
            switch result {
            case let .success(sessions):
                recordTmuxSuccess(sessions, host: host)
            case let .failure(error):
                recordTmuxFailure(error, host: host)
            }
            tmuxTasks[host] = nil
        }
    }

    private func recordKwtSuccess(
        _ inventory: KwtHostInventory,
        host: CommandHost,
        excludingWorktrees: [String: Set<KwtWorktreeIdentity>] = [:],
        recordsSuccessfulLoad: Bool = true
    ) {
        var tombstones = kwtRemovalTombstonesByHost[host] ?? [:]
        for (repository, exclusions) in excludingWorktrees {
            tombstones[repository, default: []].formUnion(exclusions)
        }
        if recordsSuccessfulLoad {
            tombstones = activeRemovalTombstones(
                tombstones,
                after: inventory
            )
        }
        if tombstones.isEmpty {
            kwtRemovalTombstonesByHost.removeValue(forKey: host)
        } else {
            kwtRemovalTombstonesByHost[host] = tombstones
        }
        var projectTombstones = kwtProjectRemovalTombstonesByHost[host] ?? []
        if recordsSuccessfulLoad {
            projectTombstones = activeProjectRemovalTombstones(
                projectTombstones,
                after: inventory
            )
        }
        if projectTombstones.isEmpty {
            kwtProjectRemovalTombstonesByHost.removeValue(forKey: host)
        } else {
            kwtProjectRemovalTombstonesByHost[host] = projectTombstones
        }
        revision &+= 1
        var entry = snapshot.kwtByHost[host] ?? .empty
        var reconciled = inventory.retainingFailedProjectWorktrees(
            from: entry.inventory,
            excludingWorktrees: tombstones
        )
        reconciled.projects.removeAll { item in
            projectTombstones.contains { $0.matches(item.project) }
        }
        entry.inventory = reconciled
        entry.inventoryRevision = revision
        if recordsSuccessfulLoad {
            entry.observationRevision = revision
            entry.state = .loaded
            entry.isFresh = true
        }
        snapshot.kwtByHost[host] = entry
    }

    private func activeRemovalTombstones(
        _ tombstones: [String: Set<KwtWorktreeIdentity>],
        after inventory: KwtHostInventory
    ) -> [String: Set<KwtWorktreeIdentity>] {
        guard inventory.projectsWarning == nil else { return tombstones }
        return tombstones.reduce(into: [:]) { active, entry in
            // A legacy-empty repository identity may still be this project,
            // so its rows keep the tombstone alive as the scene does.
            let projects = inventory.projects.filter {
                $0.project.repository == entry.key
                    || $0.project.repository.isEmpty
            }
            guard !projects.isEmpty else { return }
            if projects.contains(where: { $0.warning != nil }) {
                active[entry.key] = entry.value
                return
            }
            let retained = entry.value.filter { tombstone in
                projects.contains { project in
                    project.worktrees.contains {
                        tombstone.matches(
                            path: $0.path,
                            generation: $0.generation
                        )
                    }
                }
            }
            if !retained.isEmpty {
                active[entry.key] = retained
            }
        }
    }

    private func activeProjectRemovalTombstones(
        _ tombstones: Set<ProjectRemovalTombstone>,
        after inventory: KwtHostInventory
    ) -> Set<ProjectRemovalTombstone> {
        guard inventory.projectsWarning == nil else { return tombstones }
        return tombstones.filter { tombstone in
            inventory.projects.contains { tombstone.matches($0.project) }
        }
    }

    private static func isAuthoritative(_ inventory: KwtHostInventory) -> Bool {
        inventory.projectsWarning == nil
            && inventory.projects.allSatisfy { $0.warning == nil }
    }

    private func isSoleActiveMutation(
        hostID: UUID,
        on commandHost: CommandHost
    ) -> Bool {
        let endpointHostIDs = Set(subscribers.values.flatMap(\.registrations)
            .filter { $0.commandHost == commandHost }
            .map(\.hostID))
        let activeScopes = mutationCoordinator.scopes.filter {
            endpointHostIDs.contains($0.hostID)
        }
        return activeScopes.count == 1
            && activeScopes.first?.hostID == hostID
    }

    private func recordKwtFailure(
        _ error: any Error,
        host: CommandHost
    ) {
        revision &+= 1
        var entry = snapshot.kwtByHost[host] ?? .empty
        entry.observationRevision = revision
        entry.state = .failed(error)
        entry.isFresh = false
        snapshot.kwtByHost[host] = entry
    }

    private func recordKwtProvisioningFailure(host: CommandHost) {
        revision &+= 1
        var entry = snapshot.kwtByHost[host] ?? .empty
        entry.observationRevision = revision
        entry.state = .provisioningFailed
        entry.isFresh = false
        snapshot.kwtByHost[host] = entry
    }

    private func recordTmuxSuccess(
        _ sessions: [DiscoveredTmuxSession],
        host: CommandHost
    ) {
        revision &+= 1
        var entry = snapshot.tmuxByHost[host] ?? .empty
        entry.sessions = sessions
        entry.inventoryRevision = revision
        entry.observationRevision = revision
        entry.state = .loaded
        entry.isFresh = true
        snapshot.tmuxByHost[host] = entry
    }

    private func recordTmuxFailure(
        _ error: TmuxBinaryError,
        host: CommandHost
    ) {
        revision &+= 1
        var entry = snapshot.tmuxByHost[host] ?? .empty
        entry.observationRevision = revision
        entry.state = .failed(error)
        entry.isFresh = false
        snapshot.tmuxByHost[host] = entry
    }

    private func invalidateKwtHosts(_ hosts: Set<CommandHost>) {
        for host in hosts {
            kwtGenerations[host, default: 0] &+= 1
            kwtTasks.removeValue(forKey: host)?.cancel()
            if var entry = snapshot.kwtByHost[host] {
                entry.state = .idle
                entry.isFresh = false
                snapshot.kwtByHost[host] = entry
            }
        }
    }

    private func invalidateTmuxHosts(_ hosts: Set<CommandHost>) {
        for host in hosts {
            tmuxGenerations[host, default: 0] &+= 1
            tmuxTasks.removeValue(forKey: host)?.cancel()
            if var entry = snapshot.tmuxByHost[host] {
                entry.state = .idle
                entry.isFresh = false
                snapshot.tmuxByHost[host] = entry
            }
        }
    }

    private func registrations(
        for host: CommandHost
    ) -> [HostRegistration] {
        subscribers.values.flatMap(\.registrations).filter {
            $0.commandHost == host
        }
    }

    private func provisioningHost(for host: CommandHost) -> SSHHost? {
        registrations(for: host)
            .compactMap(\.provisioningHost)
            .filter { $0.platform == .macOS || $0.platform == .linux }
            .sorted { $0.configKey < $1.configKey }
            .first
    }

    private func isKwtFenced(_ host: CommandHost) -> Bool {
        let hostIDs = Set(registrations(for: host).map(\.hostID))
        let quarantinedScopes = Set(
            mutationCoordinator.quarantinedProjectRemovals.keys
        )
        return mutationCoordinator.scopes
            .subtracting(quarantinedScopes).contains {
                hostIDs.contains($0.hostID)
            }
    }

    private func mutationEvent(
        _ event: WorktreeMutationCoordinator.Event
    ) {
        switch event.phase {
        case .began:
            fenceGenerationsByHostID[event.scope.hostID, default: 0] &+= 1
            let hosts = Set(subscribers.values.flatMap(\.registrations)
                .filter { $0.hostID == event.scope.hostID }
                .map(\.commandHost))
            for host in hosts {
                kwtMutationEpochsByHost[host, default: 0] &+= 1
            }
            invalidateKwtHosts(hosts)
        case .ended:
            let hosts = Set(subscribers.values.flatMap(\.registrations)
                .filter { $0.hostID == event.scope.hostID }
                .map(\.commandHost))
            let tmuxHosts = hosts.intersection(subscribedTmuxHosts())
            invalidateTmuxHosts(tmuxHosts)
            for host in tmuxHosts {
                requestTmux(host)
            }
            let generation = fenceGenerationsByHostID[
                event.scope.hostID,
                default: 0
            ]
            let fenceIsSatisfied = satisfiedFenceGenerationsByHostID[
                event.scope.hostID
            ] == generation
            if !fenceIsSatisfied {
                for host in hosts {
                    if !event.removalTombstones.isEmpty {
                        kwtRemovalTombstonesByHost[host, default: [:]][
                            event.scope.projectIdentity,
                            default: []
                        ].formUnion(event.removalTombstones)
                    }
                    if event.removesProject {
                        let path = event.projectPath
                            ?? cachedProjectPath(
                                repository: event.scope.projectIdentity,
                                on: host
                            )
                        kwtProjectRemovalTombstonesByHost[host, default: []]
                            .insert(ProjectRemovalTombstone(
                                repository: event.scope.projectIdentity,
                                path: path
                            ))
                    }
                    applyRemovalTombstonesToCachedInventory(on: host)
                }
            }
            guard !mutationCoordinator.scopes.contains(where: {
                $0.hostID == event.scope.hostID
            }) else { return }
            guard !fenceIsSatisfied else { return }
            for host in hosts where subscribedKwtHosts().contains(host) {
                requestKwt(host)
            }
        case .quarantined:
            let hosts = Set(subscribers.values.flatMap(\.registrations)
                .filter { $0.hostID == event.scope.hostID }
                .map(\.commandHost))
            invalidateKwtHosts(hosts)
            for host in hosts where subscribedKwtHosts().contains(host) {
                requestKwt(host)
            }
        case .registered:
            // Registration is not fenced, so a concurrent mutation's result
            // may predate it. Advancing the epoch rejects such a result, and
            // dropping the satisfied fence makes the mutation end reload.
            let hosts = Set(subscribers.values.flatMap(\.registrations)
                .filter { $0.hostID == event.scope.hostID }
                .map(\.commandHost))
            satisfiedFenceGenerationsByHostID.removeValue(
                forKey: event.scope.hostID
            )
            for host in hosts {
                kwtMutationEpochsByHost[host, default: 0] &+= 1
                clearRemovalTombstones(
                    forRepository: event.scope.projectIdentity,
                    path: event.projectPath,
                    on: host
                )
            }
        case .willRemove:
            break
        }
    }

    private func cachedProjectPath(
        repository: String,
        on host: CommandHost
    ) -> String? {
        guard !repository.isEmpty else { return nil }
        return snapshot.kwtByHost[host]?.inventory?.projects.first {
            $0.project.repository == repository
        }?.project.path
    }

    private func clearRemovalTombstones(
        forRepository repository: String,
        path: String?,
        on host: CommandHost
    ) {
        let cleared = (kwtProjectRemovalTombstonesByHost[host] ?? [])
            .filter { tombstone in
                (!repository.isEmpty && tombstone.repository == repository)
                    || (path != nil && tombstone.path == path)
            }
        kwtProjectRemovalTombstonesByHost[host]?.subtract(cleared)
        if kwtProjectRemovalTombstonesByHost[host]?.isEmpty == true {
            kwtProjectRemovalTombstonesByHost.removeValue(forKey: host)
        }
        for repository in Set(cleared.map(\.repository) + [repository]) {
            kwtRemovalTombstonesByHost[host]?.removeValue(forKey: repository)
        }
        if kwtRemovalTombstonesByHost[host]?.isEmpty == true {
            kwtRemovalTombstonesByHost.removeValue(forKey: host)
        }
    }

    private func applyRemovalTombstonesToCachedInventory(
        on host: CommandHost
    ) {
        guard var entry = snapshot.kwtByHost[host],
              let inventory = entry.inventory
        else { return }
        var filtered = inventory.retainingFailedProjectWorktrees(
            from: inventory,
            excludingWorktrees: kwtRemovalTombstonesByHost[host] ?? [:]
        )
        let removedProjects = kwtProjectRemovalTombstonesByHost[host] ?? []
        filtered.projects.removeAll { item in
            removedProjects.contains { $0.matches(item.project) }
        }
        guard filtered != inventory else { return }
        revision &+= 1
        entry.inventory = filtered
        entry.inventoryRevision = revision
        snapshot.kwtByHost[host] = entry
    }

    private func requestSubscribedInventory() {
        for host in subscribedKwtHosts() {
            requestKwt(host)
        }
        for host in subscribedTmuxHosts() {
            requestTmux(host)
        }
    }

    private func reconcileCadence() {
        guard isApplicationActive, !subscribers.isEmpty else {
            cadenceTask?.cancel()
            cadenceTask = nil
            return
        }
        guard cadenceTask == nil else { return }
        let interval = refreshInterval
        let sleep = sleep
        cadenceTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard let self, isApplicationActive else { return }
                requestSubscribedInventory()
            }
        }
    }

    private nonisolated static func runDetached<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        let task = Task.detached(priority: .utility, operation: operation)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private nonisolated static func runDetached<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func discoverTmux(
        on host: CommandHost
    ) async -> Result<[DiscoveredTmuxSession], TmuxBinaryError> {
        let resolver = TmuxBinaryResolver()
        return switch host {
        case .local:
            await Task.detached(priority: .utility) {
                resolver.discoverSessions()
            }.value
        case let .ssh(info):
            await resolver.discoverSessions(on: info)
        }
    }
}
