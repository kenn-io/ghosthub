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

    /// This Mac, then every configured macOS and Linux host. Windows hosts
    /// install kwt only on request, so their hooks stay manual too.
    public static func all(sshHosts: [SSHHost]) -> [AgentHookTarget] {
        [AgentHookTarget(id: "", name: "This Mac", host: nil)]
            + sshHosts
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

    /// The last result for each target, by target ID.
    public private(set) var phases: [String: Phase] = [:]
    /// Connections already brought up to date this launch. The app's kwt,
    /// and so the hooks it installs, change only with an app update.
    @ObservationIgnored private var maintained: Set<AgentHookConnection> = []
    /// The check or install running for each target. Another request for
    /// the same target waits for it, so an install asked for during a check
    /// still happens.
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]

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

    /// Installs or updates hooks where needed on targets not yet brought
    /// up to date this launch. A failed target is tried again next time.
    public func maintain(_ targets: [AgentHookTarget]) async {
        let pending = targets.filter {
            maintained.insert(AgentHookConnection($0.host)).inserted
        }
        await check(pending, installing: true)
        for target in pending {
            if case .failed = phases[target.id] {
                maintained.remove(AgentHookConnection(target.host))
            }
        }
    }

    /// Some target has an agent whose hooks are missing or out of date.
    public func hooksMissing(in targets: [AgentHookTarget]) -> Bool {
        targets.contains { target in
            guard case let .ready(statuses) = phases[target.id] else { return false }
            return Self.needsInstall(statuses)
        }
    }

    /// Every target was read.
    public func checked(_ targets: [AgentHookTarget]) -> Bool {
        targets.allSatisfy { target in
            if case .ready = phases[target.id] {
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
        let previous = inFlight[target.id]
        let task = Task {
            await previous?.value
            await self.run(target, installing: installing)
        }
        inFlight[target.id] = task
        await task.value
        if inFlight[target.id] == task {
            inFlight[target.id] = nil
        }
    }

    private func run(_ target: AgentHookTarget, installing: Bool) async {
        guard let status else {
            phases[target.id] = .failed("Agent hooks are not available.")
            return
        }
        phases[target.id] = .checking
        var result = await status(target.host)
        if installing, let install,
           case let .success(statuses) = result,
           Self.needsInstall(statuses) {
            phases[target.id] = .installing
            result = await install(target.host)
        }
        switch result {
        case let .success(statuses):
            phases[target.id] = .ready(statuses)
        case let .failure(error):
            phases[target.id] = .failed(error.displayMessage)
        }
    }
}
