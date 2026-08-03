import Foundation
import GhosthubWorkspace

public struct SSHHostDraftImport: Equatable, Sendable {
    public var name: String
    public var platform: HostPlatform
    public var sshDestination: String

    public init(
        name: String,
        platform: HostPlatform,
        sshDestination: String
    ) {
        self.name = name
        self.platform = platform
        self.sshDestination = sshDestination
    }

    public init(
        tailscalePeer peer: TailscalePeer,
        username: String = NSUserName()
    ) {
        self.init(
            name: peer.hostName,
            platform: peer.platform,
            sshDestination: peer.sshDestination(username: username)
        )
    }
}

public struct SSHHostDraftListState: Equatable {
    public var drafts: [SSHHostDraft]
    public var selectedDraftID: UUID?
}

public enum SSHHostDraftListEditor {
    public static func addingDefaultHost(
        to drafts: [SSHHostDraft],
        id: UUID = UUID()
    ) -> SSHHostDraftListState {
        let draft = SSHHostDraft(
            id: id,
            configKey: uniqueConfigKey(
                base: "host",
                existingKeys: Set(drafts.map(\.configKey))
            ),
            name: "Host",
            platform: .linux,
            sshDestination: ""
        )
        return SSHHostDraftListState(
            drafts: drafts + [draft],
            selectedDraftID: draft.id
        )
    }

    public static func removingSelectedHost(
        from drafts: [SSHHostDraft],
        selectedDraftID: UUID?
    ) -> SSHHostDraftListState {
        guard let index = drafts.firstIndex(where: {
            $0.id == selectedDraftID
        }) else {
            return SSHHostDraftListState(
                drafts: drafts,
                selectedDraftID: selectedDraftID
            )
        }

        var nextDrafts = drafts
        nextDrafts.remove(at: index)
        let nextSelection = nextDrafts.indices.contains(index)
            ? nextDrafts[index].id
            : nextDrafts.last?.id
        return SSHHostDraftListState(
            drafts: nextDrafts,
            selectedDraftID: nextSelection
        )
    }

    public static func importingSSHHosts(
        _ hosts: [SSHHostDraftImport],
        into drafts: [SSHHostDraft]
    ) -> SSHHostDraftListState {
        var nextDrafts = drafts
        var existingKeys = Set(drafts.map(\.configKey))
        for host in hosts {
            let key = uniqueConfigKey(
                base: host.name
                    .lowercased()
                    .replacingOccurrences(of: " ", with: "-"),
                existingKeys: existingKeys
            )
            existingKeys.insert(key)
            nextDrafts.append(
                SSHHostDraft(
                    configKey: key,
                    name: host.name,
                    platform: host.platform,
                    sshDestination: host.sshDestination
                )
            )
        }
        return SSHHostDraftListState(
            drafts: nextDrafts,
            selectedDraftID: nextDrafts.last?.id
        )
    }

    private static func uniqueConfigKey(
        base: String,
        existingKeys: Set<String>
    ) -> String {
        var candidate = base
        var suffix = 2
        while existingKeys.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
