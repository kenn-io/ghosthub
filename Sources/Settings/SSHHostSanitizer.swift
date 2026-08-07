import Foundation
import GhosthubWorkspace

public enum SSHHostSanitizer {
    public static func launchProfiles(
        _ profiles: [TmuxLaunchProfile]
    ) -> [TmuxLaunchProfile] {
        var seenNames = Set<String>()

        return profiles.compactMap { profile in
            let name = profile.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let command = profile.command.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let normalizedName = name.lowercased()
            guard !name.isEmpty,
                  !command.isEmpty,
                  seenNames.insert(normalizedName).inserted
            else {
                return nil
            }
            return TmuxLaunchProfile(
                id: profile.id,
                name: name,
                command: command
            )
        }
    }

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
                sshDestination: sshDestination,
                launchProfiles: launchProfiles(host.launchProfiles)
            )
        }
    }
}
