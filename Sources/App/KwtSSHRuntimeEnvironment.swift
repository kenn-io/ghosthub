import Foundation
import GhosthubWorkspace

enum KwtSSHRuntimeEnvironment {
    static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var resolved = AccountCommandRunner.sanitizedProcessEnvironment(
            environment
        )
        resolved["KWT_HOME"] = StateHome.resolved(environment: environment)
            .appendingPathComponent("ssh", isDirectory: true)
            .appendingPathComponent("kwt", isDirectory: true)
            .path
        return resolved
    }
}
