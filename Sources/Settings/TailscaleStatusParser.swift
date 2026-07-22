import Foundation

public enum TailscaleStatusParseError: Error, Equatable, Sendable {
    case parseFailed(String)

    public var message: String {
        switch self {
        case let .parseFailed(message):
            return message
        }
    }
}

public enum TailscaleStatusParser {
    public static func peers(
        from data: Data
    ) -> Result<[TailscalePeer], TailscaleStatusParseError> {
        struct StatusResponse: Decodable {
            let Peer: [String: PeerNode]?
        }
        struct PeerNode: Decodable {
            let ID: String?
            let HostName: String?
            let DNSName: String?
            let OS: String?
            let Online: Bool?
        }

        let response: StatusResponse
        do {
            response = try JSONDecoder().decode(
                StatusResponse.self,
                from: data
            )
        } catch {
            return .failure(
                .parseFailed(error.localizedDescription)
            )
        }

        guard let peers = response.Peer else {
            return .success([])
        }

        let results = peers.values.compactMap { node
            -> TailscalePeer? in
            guard let hostName = node.HostName,
                  let dnsName = node.DNSName,
                  let os = node.OS
            else { return nil }
            return TailscalePeer(
                id: node.ID ?? dnsName,
                hostName: hostName,
                dnsName: dnsName,
                os: os,
                isOnline: node.Online ?? false
            )
        }
        .filter(\.isSSHCapable)
        .sorted { lhs, rhs in
            if lhs.isOnline != rhs.isOnline {
                return lhs.isOnline
            }
            return lhs.hostName.localizedCaseInsensitiveCompare(
                rhs.hostName
            ) == .orderedAscending
        }

        return .success(results)
    }
}
