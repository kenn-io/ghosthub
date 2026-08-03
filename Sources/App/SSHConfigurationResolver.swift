import Foundation
import GhosthubTmux

struct EffectiveSSHConfiguration: Equatable {
    let user: String?
    let strictHostKeyChecking: String?
    let proxyJump: String?
    let proxyCommand: String?
}

enum SSHConfigurationResolver {
    typealias ConfigurationProvider = (SSHHostInfo)
        -> EffectiveSSHConfiguration?

    static func noninteractiveHostKeyArguments(
        for host: SSHHostInfo
    ) -> [String] {
        noninteractiveHostKeyArguments(
            for: host,
            configurationProvider: configuration
        )
    }

    static func noninteractiveHostKeyArguments(
        for host: SSHHostInfo,
        configurationProvider: ConfigurationProvider
    ) -> [String] {
        guard let configuration = configurationProvider(host) else {
            return noninteractiveHostKeyArguments(effectivePolicy: nil)
        }
        var arguments = noninteractiveHostKeyArguments(
            effectivePolicy: configuration.strictHostKeyChecking
        )
        guard configuration.proxyCommand == nil,
              let proxyJump = configuration.proxyJump
        else { return arguments }
        guard let proxyHops = proxyJumpHosts(proxyJump) else {
            return arguments + ["-o", "ProxyCommand=/usr/bin/false"]
        }
        arguments.append(contentsOf: [
            "-o",
            "ProxyCommand=" + hardenedProxyCommand(
                hops: proxyHops,
                configurationProvider: configurationProvider
            ),
        ])
        return arguments
    }

    static func normalizedHostKeyPolicy(_ policy: String?) -> String? {
        switch policy?.lowercased() {
        case "true":
            return "yes"
        case "false":
            return "no"
        default:
            return policy?.lowercased()
        }
    }

    static func proxyJumpHosts(_ proxyJump: String) -> [SSHHostInfo]? {
        let destinations = proxyJump.split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        let hosts = destinations.compactMap { value in
            TmuxHostResolver.parseSSHDestination(
                String(value).trimmingCharacters(in: .whitespaces)
            )
        }
        return hosts.count == destinations.count ? hosts : nil
    }

    static func proxyJumpDestination(for host: SSHHostInfo) -> String {
        let hostname = host.hostname.contains(":")
            ? "[\(host.hostname)]"
            : host.hostname
        let destination = host.user.map { "\($0)@\(hostname)" } ?? hostname
        guard let port = host.port, port != 22 else { return destination }
        return "\(destination):\(port)"
    }

    private static func hardenedProxyCommand(
        hops: [SSHHostInfo],
        configurationProvider: ConfigurationProvider
    ) -> String {
        var previousCommand: String?
        for hop in hops {
            var arguments = ["/usr/bin/ssh"]
            arguments.append(contentsOf: noninteractiveHostKeyArguments(
                effectivePolicy: configurationProvider(hop)?
                    .strictHostKeyChecking
            ))
            if let previousCommand {
                arguments.append(contentsOf: [
                    "-o",
                    "ProxyCommand=" + previousCommand.replacingOccurrences(
                        of: "%",
                        with: "%%"
                    ),
                ])
            }
            arguments.append(contentsOf: [
                "-W", "[%h]:%p", proxyJumpDestination(for: hop),
            ])
            previousCommand = arguments
                .map(shellQuotedCommandArgument)
                .joined(separator: " ")
        }
        return previousCommand ?? "/usr/bin/false"
    }

    static func noninteractiveHostKeyArguments(
        effectivePolicy: String?
    ) -> [String] {
        noninteractiveHostKeyArguments(
            normalizedPolicy: normalizedHostKeyPolicy(effectivePolicy)
        )
    }

    private static func noninteractiveHostKeyArguments(
        normalizedPolicy: String?
    ) -> [String] {
        switch normalizedPolicy {
        case "yes", "no", "off":
            return []
        default:
            return ["-o", "StrictHostKeyChecking=yes"]
        }
    }

    static func configuration(
        for host: SSHHostInfo
    ) -> EffectiveSSHConfiguration? {
        var arguments = ["-G"]
        arguments.append(contentsOf: tmuxSSHConnectionArguments())
        if let port = host.port, port != 22 {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        let target = host.user.map { "\($0)@\(host.hostname)" }
            ?? host.hostname
        arguments.append(contentsOf: ["--", target])
        let result = TmuxBinaryResolver.runProcessInLoginShell(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            timeout: 5,
            accountShell: TmuxBinaryResolver.loginShell()
        )
        guard result.status == 0 else { return nil }
        return parse(result.stdout)
    }

    static func parse(_ output: String) -> EffectiveSSHConfiguration {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(
                maxSplits: 1,
                whereSeparator: \Character.isWhitespace
            )
            guard fields.count == 2 else { continue }
            values[String(fields[0]).lowercased()] = String(fields[1])
        }
        return EffectiveSSHConfiguration(
            user: values["user"],
            strictHostKeyChecking: normalizedHostKeyPolicy(
                values["stricthostkeychecking"]
            ),
            proxyJump: meaningfulProxyValue(values["proxyjump"]),
            proxyCommand: meaningfulProxyValue(values["proxycommand"])
        )
    }

    private static func meaningfulProxyValue(_ value: String?) -> String? {
        guard let value, value.lowercased() != "none" else { return nil }
        return value
    }
}
