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
            let sshDestination = host.sshDestination
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
}
