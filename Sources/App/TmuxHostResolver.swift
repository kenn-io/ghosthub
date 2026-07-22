import Foundation
import GhosthubTmux
import GhosthubWorkspace

enum TmuxHostResolver {
    static func resolve(_ host: HostSummary) -> TmuxHost? {
        guard host.kind == .remote else { return .local }
        guard let destination = host.sshDestination?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !destination.isEmpty
        else { return nil }
        return parseSSHDestination(destination).map(TmuxHost.ssh)
    }

    static func parseSSHDestination(_ destination: String) -> SSHHostInfo? {
        let userAndHost = destination.split(separator: "@", maxSplits: 1)
        let user: String?
        let hostAndPort: String
        if userAndHost.count == 2 {
            user = String(userAndHost[0])
            hostAndPort = String(userAndHost[1])
        } else {
            user = nil
            hostAndPort = destination
        }

        guard !hostAndPort.isEmpty else { return nil }
        let hostname: String
        let port: Int?
        if hostAndPort.hasPrefix("[") {
            guard let closingBracket = hostAndPort.firstIndex(of: "]") else {
                return nil
            }
            let hostnameStart = hostAndPort.index(
                after: hostAndPort.startIndex
            )
            hostname = String(hostAndPort[hostnameStart..<closingBracket])
            let suffix = hostAndPort[hostAndPort.index(after: closingBracket)...]
            if suffix.isEmpty {
                port = nil
            } else {
                guard suffix.first == ":",
                      let parsedPort = Int(suffix.dropFirst()) else {
                    return nil
                }
                port = parsedPort
            }
        } else if hostAndPort.filter({ $0 == ":" }).count > 1 {
            // An unbracketed IPv6 literal cannot also carry an unambiguous
            // port. Preserve the complete address and let ssh use its default.
            hostname = hostAndPort
            port = nil
        } else {
            let components = hostAndPort.split(
                separator: ":", maxSplits: 1
            )
            hostname = String(components[0])
            port = components.count == 2 ? Int(components[1]) : nil
            if components.count == 2, port == nil {
                return nil
            }
        }
        guard !hostname.isEmpty else { return nil }
        return SSHHostInfo(user: user, hostname: hostname, port: port)
    }
}
