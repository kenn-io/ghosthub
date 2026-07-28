import CryptoKit
import Foundation
import GhosthubSettings
import GhosthubWorkspace

enum ConfiguredHostOverlay {
    static func apply(
        _ configuredHosts: [SSHHost],
        to source: WorkspaceSnapshot
    ) -> WorkspaceSnapshot {
        var snapshot = source
        let localHosts = source.hosts.filter { $0.kind == .selfHost }
        let remoteHosts = source.hosts.filter { $0.kind == .remote }
        var hosts = localHosts
        var consumedHostIDs: Set<UUID> = []
        var invalidatedHostIDs: Set<UUID> = []
        var reservedHostIDs: Set<UUID> = []
        var exactMatches: [Int: HostSummary] = [:]

        // A destination match is only a migration fallback. Reserve every
        // exact config-key identity first so an earlier renamed/reordered
        // entry cannot steal the host that belongs to a later configuration.
        for (index, configured) in configuredHosts.enumerated() {
            guard let existing = remoteHosts.first(where: {
                !reservedHostIDs.contains($0.id)
                    && $0.configKey == configured.configKey
            }) else { continue }
            exactMatches[index] = existing
            reservedHostIDs.insert(existing.id)
        }

        for (index, configured) in configuredHosts.enumerated() {
            let existing = exactMatches[index] ?? remoteHosts.first {
                !consumedHostIDs.contains($0.id)
                    && !reservedHostIDs.contains($0.id)
                    && $0.sshDestination == configured.sshDestination
            }
            if let existing {
                consumedHostIDs.insert(existing.id)
                if existing.sshDestination != configured.sshDestination
                    || existing.platform != configured.platform {
                    invalidatedHostIDs.insert(existing.id)
                }
            }
            var host = existing ?? HostSummary(
                id: stableID("ssh-host|\(configured.configKey)"),
                configKey: configured.configKey,
                name: configured.name,
                kind: .remote,
                platform: configured.platform,
                sshDestination: configured.sshDestination,
                preferredTransport: .ssh,
                lastKnownReachable: false
            )
            host.configKey = configured.configKey
            host.name = configured.name
            host.kind = .remote
            host.platform = configured.platform
            host.sshDestination = configured.sshDestination
            host.preferredTransport = .ssh
            if invalidatedHostIDs.contains(host.id) {
                host.tmuxSessions = []
            }
            hosts.append(host)
        }

        let hostIDs = Set(hosts.map(\.id))
        snapshot.hosts = hosts
        snapshot.projects.removeAll {
            !hostIDs.contains($0.hostID)
                || invalidatedHostIDs.contains($0.hostID)
        }
        snapshot.worktrees.removeAll {
            !hostIDs.contains($0.hostID)
                || invalidatedHostIDs.contains($0.hostID)
        }
        let worktreeIDs = Set(snapshot.worktrees.map(\.id))
        snapshot.sessions.removeAll { session in
            if invalidatedHostIDs.contains(session.hostID) {
                return true
            }
            guard let worktreeID = session.worktreeID else { return false }
            return !worktreeIDs.contains(worktreeID)
        }
        return snapshot
    }

    private static func stableID(_ material: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
