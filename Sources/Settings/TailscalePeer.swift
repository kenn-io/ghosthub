import GhosthubWorkspace

public struct TailscalePeer: Identifiable, Equatable, Sendable {
    public let id: String
    public let hostName: String
    public let dnsName: String
    public let os: String
    public let isOnline: Bool
    public let sshUsername: String?

    public init(
        id: String,
        hostName: String,
        dnsName: String,
        os: String,
        isOnline: Bool,
        sshUsername: String?
    ) {
        self.id = id
        self.hostName = hostName
        self.dnsName = dnsName
        self.os = os
        self.isOnline = isOnline
        self.sshUsername = sshUsername
    }

    public var sshAddress: String {
        normalizedDNSName
    }

    public func sshDestination(username: String) -> String {
        let username = username.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return username.isEmpty
            ? sshAddress
            : "\(username)@\(sshAddress)"
    }

    public func resolvingSSHUsername(_ username: String?) -> Self {
        Self(
            id: id,
            hostName: hostName,
            dnsName: dnsName,
            os: os,
            isOnline: isOnline,
            sshUsername: username
        )
    }

    private var normalizedDNSName: String {
        dnsName.hasSuffix(".")
            ? String(dnsName.dropLast())
            : dnsName
    }

    fileprivate var importAddressAliases: Set<String> {
        [sshAddress, hostName, normalizedDNSName]
    }

    public var platform: HostPlatform {
        switch os.lowercased() {
        case "macos":
            return .macOS
        case "linux":
            return .linux
        case "windows":
            return .windows
        default:
            return .linux
        }
    }

    public var isSSHCapable: Bool {
        let lower = os.lowercased()
        return lower == "linux" || lower == "macos" || lower == "windows"
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
        !normalizedExistingAddresses.isDisjoint(
            with: peer.importAddressAliases.map(normalizedHost)
        )
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
                        && normalizedExisting.isDisjoint(
                            with: $0.importAddressAliases.map(normalizedHost)
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
