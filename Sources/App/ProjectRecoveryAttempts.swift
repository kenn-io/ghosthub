import GhosthubTransport

struct KwtProjectRecoveryResponse: Decodable {
    var status: String
    var project: KwtProjectRecord
}

/// A missing folder gets one automatic search per registration while it stays
/// missing. Ordinary refreshes still check whether its original path returned.
actor ProjectRecoveryAttempts {
    static let shared = ProjectRecoveryAttempts()
    private var attempted: [CommandHost: Set<String>] = [:]

    func retainRegistrations(_ projects: [KwtProjectRecord], on host: CommandHost) {
        let registered = Set(projects.map(\.registrationFingerprint))
        attempted[host] = attempted[host, default: []].intersection(registered)
    }

    func finish(_ project: KwtProjectRecord, on host: CommandHost) {
        attempted[host]?.remove(project.registrationFingerprint)
    }

    func begin(_ project: KwtProjectRecord, on host: CommandHost) -> Bool {
        attempted[host, default: []].insert(project.registrationFingerprint).inserted
    }
}
