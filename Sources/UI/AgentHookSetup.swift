import GhosthubSettings
import GhosthubWorkspace
import Observation

/// The connection fields that decide which machine an agent hook status
/// describes. Renaming a host does not change it. A nil host means this Mac.
struct AgentHookConnection: Hashable {
    var configKey: String?
    var destination: String?
    var platform: HostPlatform?
    var compression: Bool?
    var forwardAgent: Bool?

    init(_ host: SSHHost?) {
        configKey = host?.configKey
        destination = host?.sshDestination
        platform = host?.platform
        compression = host?.compression
        forwardAgent = host?.forwardAgent
    }
}

/// Agent hook status for the host Settings shows. Settings keeps one
/// section while the person switches hosts, so a load or install that
/// finishes after a switch must not change what the new host shows.
@MainActor
@Observable
final class AgentHookSetup {
    typealias Operation = (SSHHost?) async -> Result<[AgentHookSetupStatus], HostProbeError>

    private(set) var statuses: [AgentHookSetupStatus]?
    private(set) var errorMessage: String?
    private var shown: AgentHookConnection?
    private var installing: AgentHookConnection?
    /// Counts installs whose result was shown. A load that was running
    /// when one finished may have read the host before the install.
    private var shownInstalls = 0

    /// Whether the host Settings shows is installing hooks now.
    var isInstalling: Bool {
        installing != nil && installing == shown
    }

    /// Shows `host` and loads its status. Run it from a task that is
    /// cancelled when the host or its connection changes.
    func load(_ host: SSHHost?, using load: Operation) async {
        let connection = AgentHookConnection(host)
        let installsBefore = shownInstalls
        shown = connection
        statuses = nil
        errorMessage = nil
        let result = await load(host)
        guard !Task.isCancelled,
              shown == connection,
              shownInstalls == installsBefore
        else { return }
        apply(result)
    }

    /// Installs hooks on `host`. The install finishes even if the person
    /// moves to another host, but then its result is not shown.
    func install(_ host: SSHHost?, using install: Operation) async {
        let connection = AgentHookConnection(host)
        installing = connection
        errorMessage = nil
        let result = await install(host)
        if installing == connection {
            installing = nil
        }
        guard shown == connection else { return }
        apply(result)
        shownInstalls += 1
    }

    private func apply(_ result: Result<[AgentHookSetupStatus], HostProbeError>) {
        switch result {
        case let .success(loaded):
            statuses = loaded
        case let .failure(error):
            errorMessage = error.displayMessage
        }
    }
}
