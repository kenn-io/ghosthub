import Foundation
import GhosthubTransport

enum SSHCommandArguments {
    typealias NormalArgumentsProvider = @Sendable (SSHHostInfo) -> [String]

    static func noninteractive(
        for host: SSHHostInfo,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        normalArgumentsProvider: NormalArgumentsProvider = {
            SSHConnectionPool.connectionArguments(for: $0)
                + SSHConfigurationResolver.noninteractiveHostKeyArguments(
                    for: $0
                )
        }
    ) -> [String] {
        let isolation = demoSSHIsolationArguments(environment: environment)
        guard isolation.isEmpty else { return isolation }
        return normalArgumentsProvider(host)
    }

    static func connectionSnapshot(
        for host: SSHHostInfo,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider =
            SSHConfigurationResolver.configuration
    ) -> SSHConnectionArgumentsSnapshot {
        let isolation = demoSSHIsolationArguments(environment: environment)
        guard isolation.isEmpty else {
            return SSHConnectionArgumentsSnapshot(arguments: isolation)
        }
        let configuration = SSHConnectionPool.configurationSnapshot(
            for: host,
            configurationProvider: configurationProvider
        )
        let provider = configuration.configurationProvider
        let controlPath = SSHConnectionPool.authenticationIdentity(
            for: configuration
        )?.controlPath
        let snapshot = SSHConfigurationResolver.connectionArgumentsSnapshot(
            for: host,
            configurationProvider: provider
        )
        return snapshot.replacingArguments(
            snapshot.arguments
                + SSHConnectionPool.proxyArguments(
                    for: configuration.target,
                    configurationProvider: provider
                )
                + SSHConnectionPool.connectionArguments(
                    controlPath: controlPath
                )
                + SSHConfigurationResolver.noninteractiveHostKeyArguments(
                    for: host,
                    configurationProvider: provider
                )
        )
    }
}
