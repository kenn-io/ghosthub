import Foundation
import GhosthubTmux

struct EffectiveSSHConfiguration: Equatable, Sendable {
    let user: String?
    let strictHostKeyChecking: String?
    let proxyJump: String?
    let proxyCommand: String?
    let hostname: String?
    let port: Int?
    let hostKeyAlias: String?
    let resolvedOptions: [String]

    init(
        user: String?,
        strictHostKeyChecking: String?,
        proxyJump: String?,
        proxyCommand: String?,
        hostname: String? = nil,
        port: Int? = nil,
        hostKeyAlias: String? = nil,
        resolvedOptions: [String] = []
    ) {
        self.user = user
        self.strictHostKeyChecking = strictHostKeyChecking
        self.proxyJump = proxyJump
        self.proxyCommand = proxyCommand
        self.hostname = hostname
        self.port = port
        self.hostKeyAlias = hostKeyAlias
        self.resolvedOptions = resolvedOptions
    }
}

struct EffectiveProxyJumpHop: Sendable {
    let host: SSHHostInfo
    let configuration: EffectiveSSHConfiguration
}

enum SSHConfigurationResolver {
    typealias ConfigurationProvider = @Sendable (SSHHostInfo)
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
        hostKeyArguments(
            for: host,
            proxyBatchMode: "yes",
            configurationProvider: configurationProvider
        )
    }

    static func interactiveHostKeyArguments(
        for host: SSHHostInfo,
        configurationProvider: ConfigurationProvider = configuration
    ) -> [String] {
        hostKeyArguments(
            for: host,
            proxyBatchMode: "no",
            configurationProvider: configurationProvider
        )
    }

    static func authenticationHostKeyArguments(
        for host: SSHHostInfo,
        configurationProvider: ConfigurationProvider = configuration
    ) -> [String] {
        guard let configuration = configurationProvider(host),
              configuration.proxyCommand == nil
        else {
            return [
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UpdateHostKeys=no",
                "-o", "ProxyCommand=/usr/bin/false",
            ]
        }
        return noninteractiveHostKeyArguments(
            effectivePolicy: configuration.strictHostKeyChecking
        )
    }

    private static func hostKeyArguments(
        for host: SSHHostInfo,
        proxyBatchMode: String,
        configurationProvider: ConfigurationProvider
    ) -> [String] {
        guard let configuration = configurationProvider(host) else {
            return [
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UpdateHostKeys=no",
                "-o", "ProxyCommand=/usr/bin/false",
            ]
        }
        var arguments = noninteractiveHostKeyArguments(
            effectivePolicy: configuration.strictHostKeyChecking
        )
        guard configuration.proxyCommand == nil else {
            return arguments + ["-o", "ProxyCommand=/usr/bin/false"]
        }
        guard let proxyJump = configuration.proxyJump else { return arguments }
        guard let proxyHops = effectiveProxyJumpHops(
            proxyJump,
            configurationProvider: configurationProvider
        ) else {
            return arguments + ["-o", "ProxyCommand=/usr/bin/false"]
        }
        arguments.append(contentsOf: [
            "-o",
            "ProxyCommand=" + hardenedProxyCommand(
                hops: proxyHops,
                batchMode: proxyBatchMode
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

    static func effectiveProxyJumpHops(
        _ proxyJump: String,
        configurationProvider: ConfigurationProvider
    ) -> [EffectiveProxyJumpHop]? {
        guard let hosts = proxyJumpHosts(proxyJump) else { return nil }
        var hops: [EffectiveProxyJumpHop] = []
        for host in hosts {
            guard let configuration = configurationProvider(host),
                  configuration.proxyJump == nil,
                  configuration.proxyCommand == nil
            else { return nil }
            hops.append(EffectiveProxyJumpHop(
                host: host,
                configuration: configuration
            ))
        }
        return hops
    }

    static func proxyJumpDestination(for host: SSHHostInfo) -> String {
        let hostname = host.hostname.contains(":")
            ? "[\(host.hostname)]"
            : host.hostname
        let destination = host.user.map { "\($0)@\(hostname)" } ?? hostname
        guard let port = host.port else { return destination }
        return "\(destination):\(port)"
    }

    private static func hardenedProxyCommand(
        hops: [EffectiveProxyJumpHop],
        batchMode: String
    ) -> String {
        var previousCommand: String?
        for hop in hops {
            var arguments = [
                "/usr/bin/ssh",
                "-o", "BatchMode=\(batchMode)",
                "-o", "ConnectTimeout=10",
                "-o", "ConnectionAttempts=1",
            ]
            arguments.append(contentsOf: noninteractiveHostKeyArguments(
                effectivePolicy: hop.configuration.strictHostKeyChecking
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
            arguments.append(contentsOf: proxyCommandHopArguments(
                for: hop.host
            ))
            previousCommand = arguments
                .map(shellQuotedCommandArgument)
                .joined(separator: " ")
        }
        return previousCommand ?? "/usr/bin/false"
    }

    static func proxyCommandHopArguments(for host: SSHHostInfo) -> [String] {
        var arguments: [String] = []
        if let port = host.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        arguments.append(contentsOf: [
            "-W", "[%h]:%p", sshDestination(for: host),
        ])
        return arguments
    }

    private static func sshDestination(for host: SSHHostInfo) -> String {
        host.user.map { "\($0)@\(host.hostname)" } ?? host.hostname
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
            return [
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UpdateHostKeys=no",
            ]
        }
    }

    static func configuration(
        for host: SSHHostInfo
    ) -> EffectiveSSHConfiguration? {
        var arguments = ["-G"]
        arguments.append(contentsOf: tmuxSSHConnectionArguments())
        if let port = host.port {
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

    static func effectiveHost(
        for host: SSHHostInfo,
        configurationProvider: ConfigurationProvider = configuration
    ) -> SSHHostInfo {
        guard let configuration = configurationProvider(host) else {
            return host
        }
        return SSHHostInfo(
            user: configuration.user ?? host.user,
            hostname: configuration.hostname ?? host.hostname,
            port: configuration.port ?? host.port,
            platform: host.platform
        )
    }

    static func snapshotConnectionArguments(
        for host: SSHHostInfo,
        configurationProvider: ConfigurationProvider
    ) -> [String] {
        guard let configuration = configurationProvider(host) else {
            return [
                "-F", "/dev/null",
                "-o", "ProxyCommand=/usr/bin/false",
            ]
        }
        var arguments = [
            "-F", "/dev/null",
            "-o", "CanonicalizeHostname=no",
        ]
        if let hostname = configuration.hostname {
            arguments.append(contentsOf: ["-o", "HostName=\(hostname)"])
        }
        if let user = configuration.user {
            arguments.append(contentsOf: ["-o", "User=\(user)"])
        }
        if let port = configuration.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        if let hostKeyAlias = configuration.hostKeyAlias {
            arguments.append(contentsOf: [
                "-o", "HostKeyAlias=\(hostKeyAlias)",
            ])
        }
        let preservedOptions = [
            "userknownhostsfile",
            "globalknownhostsfile",
            "knownhostscommand",
            "revokedhostkeys",
            "hostkeyalgorithms",
            "casignaturealgorithms",
            "checkhostip",
            "hashknownhosts",
            "verifyhostkeydns",
            "visualhostkey",
            "fingerprinthash",
            "addressfamily",
            "bindaddress",
            "bindinterface",
        ]
        for option in configuration.resolvedOptions {
            guard let separator = option.firstIndex(of: "=") else { continue }
            let name = String(option[..<separator])
            guard preservedOptions.contains(name) else { continue }
            let value = option[option.index(after: separator)...]
            arguments.append(contentsOf: ["-o", "\(name)=\(value)"])
        }
        return arguments
    }

    static func parse(_ output: String) -> EffectiveSSHConfiguration {
        var values: [String: String] = [:]
        var optionValues: [String: [String]] = [:]
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(
                maxSplits: 1,
                whereSeparator: \Character.isWhitespace
            )
            guard fields.count == 2 else { continue }
            let name = String(fields[0]).lowercased()
            let value = String(fields[1])
            values[name] = value
            optionValues[name, default: []].append(value)
        }
        let resolvedOptions = optionValues.keys.sorted().flatMap { name in
            optionValues[name, default: []].map { value in
                "\(name)=\(value)"
            }
        }
        return EffectiveSSHConfiguration(
            user: values["user"],
            strictHostKeyChecking: normalizedHostKeyPolicy(
                values["stricthostkeychecking"]
            ),
            proxyJump: meaningfulProxyValue(values["proxyjump"]),
            proxyCommand: meaningfulProxyValue(values["proxycommand"]),
            hostname: values["hostname"],
            port: values["port"].flatMap(Int.init),
            hostKeyAlias: meaningfulProxyValue(values["hostkeyalias"]),
            resolvedOptions: resolvedOptions
        )
    }

    private static func meaningfulProxyValue(_ value: String?) -> String? {
        guard let value, value.lowercased() != "none" else { return nil }
        return value
    }
}
