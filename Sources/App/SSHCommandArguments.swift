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
}
