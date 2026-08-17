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

    public func sshDestination(defaultUsername: String) -> String {
        sshDestination(username: sshUsername ?? defaultUsername)
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
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: Substring
        if let atIndex = address.firstIndex(of: "@") {
            host = address[address.index(after: atIndex)...]
        } else {
            host = address[...]
        }
        return host.hasSuffix(".")
            ? String(host.dropLast()).lowercased()
            : String(host).lowercased()
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
        normalizedExistingAddresses.contains(normalizedHost(peer.sshAddress))
    }

    public static func defaultSelectedPeerIDs(
        peers _: [TailscalePeer],
        existingAddresses _: Set<String>
    ) -> Set<String> {
        []
    }

    public static func selectedPeers(
        _ peers: [TailscalePeer],
        selectedIDs: Set<String>
    ) -> [TailscalePeer] {
        peers.filter { selectedIDs.contains($0.id) }
    }
}
