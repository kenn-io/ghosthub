import Foundation
import GhosthubTmux
import GhosthubWorkspace

enum SSHConnectionPool {
    private static let directoryName = "ssh"
    private static let controlName = "control-%C"

    static func connectionArguments() -> [String] {
        guard let path = preparedControlPath() else { return [] }
        return connectionArguments(controlPath: path)
    }

    static func isAuthenticated(_ host: SSHHostInfo) -> Bool {
        guard let path = preparedControlPath() else { return false }
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

    static func controlPath() -> String? {
        preparedControlPath()
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

    private static func preparedControlPath(
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
            return directory.appendingPathComponent(controlName).path
        } catch {
            return nil
        }
    }
}
