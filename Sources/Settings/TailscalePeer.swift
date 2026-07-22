import GhosthubWorkspace

public struct TailscalePeer: Identifiable, Equatable, Sendable {
    public let id: String
    public let hostName: String
    public let dnsName: String
    public let os: String
    public let isOnline: Bool

    public init(
        id: String,
        hostName: String,
        dnsName: String,
        os: String,
        isOnline: Bool
    ) {
        self.id = id
        self.hostName = hostName
        self.dnsName = dnsName
        self.os = os
        self.isOnline = isOnline
    }

    public var sshAddress: String {
        dnsName.hasSuffix(".")
            ? String(dnsName.dropLast())
            : dnsName
    }

    public var platform: HostPlatform {
        switch os.lowercased() {
        case "macos":
            return .macOS
        case "linux":
            return .linux
        default:
            return .linux
        }
    }

    public var isSSHCapable: Bool {
        let lower = os.lowercased()
        return lower == "linux" || lower == "macos"
    }
}

public enum TailscalePeerLoadResult: Equatable, Sendable {
    case success([TailscalePeer])
    case failure(String)
}

public enum TailscalePeerImportSelection {
    public static func normalizedHost(
        _ address: String
    ) -> String {
        if let atIndex = address.firstIndex(of: "@") {
            return String(address[address.index(after: atIndex)...])
        }
        return address
    }

    public static func normalizedExistingAddresses(
        _ addresses: Set<String>
    ) -> Set<String> {
        Set(addresses.map(normalizedHost))
    }

    public static func alreadyImported(
        _ peer: TailscalePeer,
        existingAddresses: Set<String>
    ) -> Bool {
        alreadyImported(
            peer,
            normalizedExistingAddresses: normalizedExistingAddresses(
                existingAddresses
            )
        )
    }

    public static func alreadyImported(
        _ peer: TailscalePeer,
        normalizedExistingAddresses: Set<String>
    ) -> Bool {
        normalizedExistingAddresses
            .contains(normalizedHost(peer.sshAddress))
    }

    public static func defaultSelectedPeerIDs(
        peers: [TailscalePeer],
        existingAddresses: Set<String>
    ) -> Set<String> {
        let normalizedExisting = normalizedExistingAddresses(
            existingAddresses
        )
        return Set(
            peers
                .filter {
                    $0.isOnline
                        && !normalizedExisting.contains(
                            normalizedHost($0.sshAddress)
                        )
                }
                .map(\.id)
        )
    }

    public static func selectedPeers(
        _ peers: [TailscalePeer],
        selectedIDs: Set<String>
    ) -> [TailscalePeer] {
        peers.filter { selectedIDs.contains($0.id) }
    }
}
