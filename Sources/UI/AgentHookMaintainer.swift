import GhosthubSettings
import Observation

/// A machine whose kwt agent hooks Ghosthub can manage. A nil host is this
/// Mac.
public struct AgentHookTarget: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var host: SSHHost?

    public init(id: String, name: String, host: SSHHost?) {
        self.id = id
        self.name = name
        self.host = host
    }

    /// This Mac, then every saved and discovered macOS and Linux host. A
    /// discovered host that shares a saved host's destination or key is
    /// that saved host. Windows hosts install kwt only on request, so their
    /// hooks stay manual too.
    public static func all(
        sshHosts: [SSHHost],
        discovered: [SSHHost] = []
    ) -> [AgentHookTarget] {
        let destinations = Set(sshHosts.map(\.sshDestination))
        var keys = Set(sshHosts.map(\.configKey))
        let others = discovered.filter {
            !destinations.contains($0.sshDestination) && keys.insert($0.configKey).inserted
        }
        return [AgentHookTarget(id: "", name: "This Mac", host: nil)]
            + (sshHosts + others)
            .filter { $0.platform == .macOS || $0.platform == .linux }
            .map { AgentHookTarget(id: $0.configKey, name: $0.name, host: $0) }
    }
}

/// Reads and installs agent hooks across hosts, and keeps them current
/// when the person chose that. Settings → Agents shows what it found.
@MainActor
@Observable
public final class AgentHookMaintainer {
    public typealias Operation = @Sendable (SSHHost?) async
        -> Result<[AgentHookSetupStatus], HostProbeError>

    public enum Phase: Equatable, Sendable {
        case checking
        case installing
        case ready([AgentHookSetupStatus])
        case failed(String)
    }

    public static let shared = AgentHookMaintainer()

    /// Supplied by the app at launch; without them every check fails.
    public var status: Operation?
    public var install: Operation?

    /// Hosts found outside Settings, such as exe.dev VMs. The app keeps
    /// this current.
    public var discoveredHosts: [SSHHost] = []
    /// The last result for each connection. A host whose connection details
    /// change is a different connection, so it is read again.
    private var phases: [AgentHookConnection: Phase] = [:]
    /// Connections already brought up to date this launch. The app's kwt,
    /// and so the hooks it installs, change only with an app update.
    @ObservationIgnored private var maintained: Set<AgentHookConnection> = []
    /// The check or install running for each target. Another request for
    /// the same target waits for it, so an install asked for during a check
    /// still happens.
    @ObservationIgnored private var inFlight: [AgentHookConnection: Task<Void, Never>] = [:]

    public init(status: Operation? = nil, install: Operation? = nil) {
        self.status = status
        self.install = install
    }

    /// Reads each target's hooks. With `installing`, also installs where an
    /// agent on that host lacks current hooks.
    public func check(_ targets: [AgentHookTarget], installing: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for target in targets {
                group.addTask { await self.check(target, installing: installing) }
            }
        }
    }

    /// This Mac and every saved or discovered host whose hooks Ghosthub
    /// manages.
    public func targets(sshHosts: [SSHHost]) -> [AgentHookTarget] {
        AgentHookTarget.all(sshHosts: sshHosts, discovered: discoveredHosts)
    }

    /// The last result for `target`'s current connection.
    public func phase(_ target: AgentHookTarget) -> Phase? {
        phases[AgentHookConnection(target.host)]
    }

    /// Installs or updates hooks where needed on targets not yet brought
    /// up to date this launch. A failed target is tried again next time.
    public func maintain(_ targets: [AgentHookTarget]) async {
        let pending = targets.filter {
            maintained.insert(AgentHookConnection($0.host)).inserted
        }
        await check(pending, installing: true)
        for target in pending {
            if case .failed = phase(target) {
                maintained.remove(AgentHookConnection(target.host))
            }
        }
    }

    /// Some target has an agent whose hooks are missing or out of date.
    public func hooksMissing(in targets: [AgentHookTarget]) -> Bool {
        targets.contains { target in
            guard case let .ready(statuses) = phase(target) else { return false }
            return Self.needsInstall(statuses)
        }
    }

    /// Every target was read.
    public func checked(_ targets: [AgentHookTarget]) -> Bool {
        targets.allSatisfy { target in
            if case .ready = phase(target) {
                return true
            }
            return false
        }
    }

    public static func needsInstall(_ statuses: [AgentHookSetupStatus]) -> Bool {
        statuses.contains { $0.available && !$0.current }
    }

    private func check(_ target: AgentHookTarget, installing: Bool) async {
        // Chain after the request already running for this target. A loop
        // that awaits a finished task never yields the main actor, so the
        // task's owner could never clear it.
        let connection = AgentHookConnection(target.host)
        let previous = inFlight[connection]
        let task = Task {
            await previous?.value
            await self.run(target, installing: installing)
        }
        inFlight[connection] = task
        await task.value
        if inFlight[connection] == task {
            inFlight[connection] = nil
        }
    }

    private func run(_ target: AgentHookTarget, installing: Bool) async {
        let connection = AgentHookConnection(target.host)
        guard let status else {
            phases[connection] = .failed("Agent hooks are not available.")
            return
        }
        phases[connection] = .checking
        var result = await status(target.host)
        if installing, let install,
           case let .success(statuses) = result,
           Self.needsInstall(statuses) {
            phases[connection] = .installing
            result = await install(target.host)
        }
        switch result {
        case let .success(statuses):
            phases[connection] = .ready(statuses)
        case let .failure(error):
            phases[connection] = .failed(error.displayMessage)
        }
    }
}
