import CryptoKit
import Foundation
import GhosthubTmux
import GhosthubWorkspace

enum SSHConnectionPool {
    private static let directoryName = "ssh"

    static func connectionArguments(for host: SSHHostInfo) -> [String] {
        guard let path = preparedControlPath(for: host) else { return [] }
        return connectionArguments(controlPath: path)
    }

    static func isAuthenticated(_ host: SSHHostInfo) -> Bool {
        guard let path = preparedControlPath(for: host) else { return false }
        let result = TmuxBinaryResolver.runProcessInLoginShell(
            executable: "/usr/bin/ssh",
            arguments: checkArguments(for: host, controlPath: path),
            timeout: 3,
            accountShell: TmuxBinaryResolver.loginShell()
        )
        return result.status == 0
    }

    static func connectionArguments(controlPath: String) -> [String] {
        ["-o", "ControlPath=\(controlPath)"]
    }

    static func controlPath(for host: SSHHostInfo) -> String? {
        preparedControlPath(for: host)
    }

    static func authenticationArguments(
        for host: SSHHostInfo,
        controlPath: String,
        hostKeyArguments: [String]
    ) -> [String] {
        var arguments = [
            "-N",
            "-o", "BatchMode=no",
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "ControlPath=\(controlPath)",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=15",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        arguments.append(contentsOf: hostKeyArguments)
        if let port = host.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        arguments.append(contentsOf: ["--", destination(for: host)])
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
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider
    ) -> String {
        let configuration = configurationProvider(host)
        var route = [routeComponent(host, configuration)]
        if let proxyJump = configuration?.proxyJump,
           let hops = SSHConfigurationResolver.proxyJumpHosts(proxyJump) {
            route.append(contentsOf: hops.map {
                routeComponent($0, configurationProvider($0))
            })
        }
        let digest = SHA256.hash(data: Data(route.joined(separator: "\n").utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
        return "control-\(digest)"
    }

    private static func routeComponent(
        _ host: SSHHostInfo,
        _ configuration: EffectiveSSHConfiguration?
    ) -> String {
        [
            destination(for: host),
            host.port.map(String.init) ?? "",
            configuration?.hostname ?? "",
            configuration?.user ?? "",
            configuration?.port.map(String.init) ?? "",
            configuration?.proxyJump ?? "",
            configuration?.proxyCommand ?? "",
        ].joined(separator: "\u{1f}")
    }

    private static func preparedControlPath(
        for host: SSHHostInfo,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        let directory = StateHome.resolved(
            environment: environment,
            fileManager: fileManager
        ).appendingPathComponent(directoryName, isDirectory: true)
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
                for: host,
                configurationProvider: SSHConfigurationResolver.configuration
            )
            return directory.appendingPathComponent(name).path
        } catch {
            return nil
        }
    }
}
