import Foundation
import GhosthubWorkspace

public enum SSHHostSanitizer {
    public static func sshHosts(
        _ hosts: [SSHHost]
    ) -> [SSHHost] {
        var seenKeys = Set<String>()

        return hosts.compactMap { host in
            let configKey = host.configKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let name = host.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let sshDestination = normalizedSSHDestination(
                host.sshDestination.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
            guard !configKey.isEmpty,
                  !name.isEmpty,
                  !sshDestination.isEmpty,
                  !seenKeys.contains(configKey)
            else {
                return nil
            }
            seenKeys.insert(configKey)

            return SSHHost(
                configKey: configKey,
                name: name,
                platform: host.platform,
                sshDestination: sshDestination
            )
        }
    }

    private static func normalizedSSHDestination(
        _ destination: String
    ) -> String {
        let hostStart: String.Index
        if let separator = destination.firstIndex(of: "@") {
            hostStart = destination.index(after: separator)
        } else {
            hostStart = destination.startIndex
        }

        let hostAndPort = destination[hostStart...]
        let hostEnd = hostAndPort.firstIndex(of: ":")
            ?? destination.endIndex
        let hostname = hostAndPort[..<hostEnd]
        let hostnameWithoutRootDot = hostname.last == "."
            ? hostname.dropLast()
            : hostname[...]
        guard hostnameWithoutRootDot.lowercased().hasSuffix(".ts.net"),
              let shortHostname = hostnameWithoutRootDot.split(
                  separator: "."
              ).first
        else { return destination }

        return String(
            destination[..<hostStart]
                + shortHostname
                + destination[hostEnd...]
        )
    }
}
