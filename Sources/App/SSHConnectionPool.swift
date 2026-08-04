import CryptoKit
import Foundation
import GhosthubTmux
import GhosthubWorkspace

struct SSHAuthenticationTarget: Hashable, Sendable {
    let host: SSHHostInfo
    let precedingProxyHops: [SSHHostInfo]

    var route: [SSHHostInfo] {
        precedingProxyHops + [host]
    }

    var precedingTarget: SSHAuthenticationTarget? {
        guard let host = precedingProxyHops.last else { return nil }
        return SSHAuthenticationTarget(
            host: host,
            precedingProxyHops: Array(precedingProxyHops.dropLast())
        )
    }
}

struct SSHAuthenticationIdentity: Equatable, Sendable {
    let target: SSHAuthenticationTarget
    let controlPath: String
}

enum SSHConnectionPool {
    private struct ResolvedTarget: Sendable {
        let target: SSHAuthenticationTarget
        let configurations: [SSHHostInfo: EffectiveSSHConfiguration]

        var configurationProvider:
            SSHConfigurationResolver.ConfigurationProvider {
            let configurations = configurations
            return { configurations[$0] }
        }
    }

    private static let directoryName = "ssh"
    private static let appSessionID = UUID().uuidString

    static func connectionArguments(for host: SSHHostInfo) -> [String] {
        connectionArguments(controlPath: controlPath(for: host))
    }

    static func isAuthenticated(_ host: SSHHostInfo) -> Bool {
        guard let path = controlPath(for: host) else { return false }
        return isAuthenticated(host, controlPath: path)
    }

    static func isAuthenticated(_ target: SSHAuthenticationTarget) -> Bool {
        guard let path = controlPath(for: target) else { return false }
        return isAuthenticated(target.host, controlPath: path)
    }

    static func isAuthenticated(
        _ host: SSHHostInfo,
        controlPath: String
    ) -> Bool {
        let result = TmuxBinaryResolver.runProcessInLoginShell(
            executable: "/usr/bin/ssh",
            arguments: checkArguments(for: host, controlPath: controlPath),
            timeout: 3,
            accountShell: TmuxBinaryResolver.loginShell()
        )
        return result.status == 0
    }

    static func connectionArguments(controlPath: String?) -> [String] {
        var arguments = [
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
        ]
        if let controlPath {
            arguments.append(contentsOf: [
                "-o", "ControlPath=\(controlPath)",
            ])
        }
        return arguments
    }

    static func controlPath(for host: SSHHostInfo) -> String? {
        authenticationIdentity(for: host)?.controlPath
    }

    static func controlPath(for target: SSHAuthenticationTarget) -> String? {
        authenticationIdentity(for: target)?.controlPath
    }

    static func authenticationIdentity(
        for host: SSHHostInfo,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider =
            SSHConfigurationResolver.configuration
    ) -> SSHAuthenticationIdentity? {
        let resolved = resolvedTarget(
            for: host,
            configurationProvider: configurationProvider
        )
        guard let controlPath = preparedControlPath(
            for: resolved.target,
            configurationProvider: resolved.configurationProvider
        ) else { return nil }
        return SSHAuthenticationIdentity(
            target: resolved.target,
            controlPath: controlPath
        )
    }

    static func authenticationIdentity(
        for target: SSHAuthenticationTarget,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider =
            SSHConfigurationResolver.configuration
    ) -> SSHAuthenticationIdentity? {
        var configurations: [SSHHostInfo: EffectiveSSHConfiguration] = [:]
        for host in target.route {
            if let configuration = configurationProvider(host) {
                configurations[host] = configuration
            }
        }
        let snapshotConfigurations = configurations
        let snapshot: SSHConfigurationResolver.ConfigurationProvider = {
            snapshotConfigurations[$0]
        }
        guard let controlPath = preparedControlPath(
            for: target,
            configurationProvider: snapshot
        ) else { return nil }
        return SSHAuthenticationIdentity(
            target: target,
            controlPath: controlPath
        )
    }

    static func authenticationArguments(
        for host: SSHHostInfo,
        controlPath: String,
        hostKeyArguments: [String]
    ) -> [String] {
        let target = SSHAuthenticationTarget(
            host: host,
            precedingProxyHops: []
        )
        return authenticationArguments(
            for: target,
            controlPath: controlPath,
            hostKeyArguments: hostKeyArguments,
            proxyArguments: proxyArguments(for: target)
        )
    }

    static func authenticationArguments(
        for target: SSHAuthenticationTarget,
        controlPath: String,
        hostKeyArguments: [String],
        proxyArguments: [String]
    ) -> [String] {
        var arguments = [
            "-N",
            "-o", "BatchMode=no",
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "ForkAfterAuthentication=no",
            "-o", "ControlPath=\(controlPath)",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=15",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        arguments.append(contentsOf: hostKeyArguments)
        arguments.append(contentsOf: proxyArguments)
        if let port = target.host.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        arguments.append(contentsOf: ["--", destination(for: target.host)])
        return arguments
    }

    static func checkArguments(
        for host: SSHHostInfo,
        controlPath: String
    ) -> [String] {
        var arguments = [
            "-O", "check",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
            "-o", "ControlPath=\(controlPath)",
        ]
        if let port = host.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        arguments.append(contentsOf: ["--", destination(for: host)])
        return arguments
    }

    private static func destination(for host: SSHHostInfo) -> String {
        host.user.map { "\($0)@\(host.hostname)" } ?? host.hostname
    }

    static func controlName(
        for host: SSHHostInfo,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider,
        sessionID: String = appSessionID
    ) -> String {
        controlName(
            for: configuredTarget(
                for: host,
                configurationProvider: configurationProvider
            ),
            configurationProvider: configurationProvider,
            sessionID: sessionID
        )
    }

    static func controlName(
        for target: SSHAuthenticationTarget,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider,
        sessionID: String = appSessionID
    ) -> String {
        let route = target.route.map {
            routeComponent($0, configurationProvider($0))
        }
        let identity = ([sessionID] + route).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return "control-\(digest)"
    }

    static func configuredTarget(
        for host: SSHHostInfo,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider =
            SSHConfigurationResolver.configuration
    ) -> SSHAuthenticationTarget {
        resolvedTarget(
            for: host,
            configurationProvider: configurationProvider
        ).target
    }

    static func proxyArguments(
        for target: SSHAuthenticationTarget,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider =
            SSHConfigurationResolver.configuration
    ) -> [String] {
        guard let configuration = configurationProvider(target.host),
              configuration.proxyCommand == nil,
              !target.precedingProxyHops.isEmpty
              || configuration.proxyJump == nil
        else {
            return [
                "-o", "ProxyJump=none",
                "-o", "ProxyCommand=/usr/bin/false",
            ]
        }
        guard let command = proxyCommand(for: target) else {
            return ["-o", "ProxyJump=none", "-o", "ProxyCommand=none"]
        }
        return [
            "-o", "ProxyJump=none",
            "-o", "ProxyCommand=\(command)",
        ]
    }

    static func proxyCommand(
        for target: SSHAuthenticationTarget
    ) -> String? {
        guard let proxy = target.precedingTarget,
              let controlPath = controlPath(for: proxy)
        else { return nil }
        var arguments = [
            "/usr/bin/ssh",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
            "-o", "ControlPath=\(controlPath)",
        ]
        if let port = proxy.host.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        arguments.append(contentsOf: [
            "-W", "[%h]:%p", destination(for: proxy.host),
        ])
        return arguments.map(shellQuotedCommandArgument).joined(separator: " ")
    }

    static func removeStaleControlSockets(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        let directory = controlDirectory(
            environment: environment,
            fileManager: fileManager
        )
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.lastPathComponent.hasPrefix("control-") {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func routeComponent(
        _ host: SSHHostInfo,
        _ configuration: EffectiveSSHConfiguration?
    ) -> String {
        let hostPort = host.port.map { String($0) } ?? ""
        let configurationPort = configuration?.port.map { String($0) } ?? ""
        let hostKeyPolicy = SSHConfigurationResolver.normalizedHostKeyPolicy(
            configuration?.strictHostKeyChecking
        ) ?? ""
        let components: [String] = [
            destination(for: host),
            hostPort,
            configuration?.hostname ?? "",
            configuration?.user ?? "",
            configurationPort,
            configuration?.hostKeyAlias ?? "",
            hostKeyPolicy,
            configuration?.proxyJump ?? "",
            configuration?.proxyCommand ?? "",
        ]
        return components.joined(separator: "\u{1f}")
    }

    private static func preparedControlPath(
        for target: SSHAuthenticationTarget,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        let directory = controlDirectory(
            environment: environment,
            fileManager: fileManager
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let name = controlName(
                for: target,
                configurationProvider: configurationProvider
            )
            return directory.appendingPathComponent(name).path
        } catch {
            return nil
        }
    }

    private static func resolvedTarget(
        for host: SSHHostInfo,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider
    ) -> ResolvedTarget {
        var configurations: [SSHHostInfo: EffectiveSSHConfiguration] = [:]
        let configuration = configurationProvider(host)
        if let configuration {
            configurations[host] = configuration
        }
        guard let proxyJump = configuration?.proxyJump,
              let proxyHosts = SSHConfigurationResolver.proxyJumpHosts(
                  proxyJump
              )
        else {
            return ResolvedTarget(
                target: SSHAuthenticationTarget(
                    host: host,
                    precedingProxyHops: []
                ),
                configurations: configurations
            )
        }

        var hops: [SSHHostInfo] = []
        for proxyHost in proxyHosts {
            guard let proxyConfiguration = configurationProvider(proxyHost),
                  proxyConfiguration.proxyJump == nil,
                  proxyConfiguration.proxyCommand == nil
            else {
                return ResolvedTarget(
                    target: SSHAuthenticationTarget(
                        host: host,
                        precedingProxyHops: []
                    ),
                    configurations: configurations
                )
            }
            configurations[proxyHost] = proxyConfiguration
            hops.append(proxyHost)
        }
        return ResolvedTarget(
            target: SSHAuthenticationTarget(
                host: host,
                precedingProxyHops: hops
            ),
            configurations: configurations
        )
    }

    private static func controlDirectory(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL {
        StateHome.resolved(
            environment: environment,
            fileManager: fileManager
        ).appendingPathComponent(directoryName, isDirectory: true)
    }
}
