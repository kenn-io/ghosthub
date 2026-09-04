import Foundation
import GhosthubTransport

/// Runs one remote command through kwt without exposing OpenSSH arguments to
/// the app. Long-lived terminal presentations continue to use explicit leases.
struct KwtSSHCommandClient: Sendable {
    typealias Runner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) -> AccountCommandOutput

    private let runner: Runner
    private let binaryPath: String?
    private let environment: [String: String]
    private let maximumOutputBytes: Int

    init(
        runner: Runner? = nil,
        binaryPath: String? = KwtBinaryLocator.bundledPath(),
        environment: [String: String]? = nil,
        maximumOutputBytes: Int = AccountCommandRunner.defaultMaximumOutputBytes
    ) {
        let processEnvironment = environment
            ?? KwtSSHRuntimeEnvironment.resolved()
        let environmentOverrides = processEnvironment["KWT_HOME"].map {
            ["KWT_HOME": $0]
        } ?? [:]
        self.runner = runner ?? { executable, arguments, timeout in
            AccountCommandRunner.runProcess(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                environmentOverrides: environmentOverrides,
                maximumOutputBytes: maximumOutputBytes
            )
        }
        self.binaryPath = binaryPath
        self.environment = processEnvironment
        self.maximumOutputBytes = maximumOutputBytes
    }

    func run(
        on host: SSHHostInfo,
        command: String,
        timeout: TimeInterval,
        expectedRouteIdentity: String? = nil
    ) async -> AccountCommandOutput {
        let demoArguments = demoSSHIsolationArguments(environment: environment)
        if !demoArguments.isEmpty {
            return await Self.runDetached {
                AccountCommandRunner(
                    maximumOutputBytes: maximumOutputBytes
                ).runRemoteLoginShell(
                    host: host,
                    connectionArguments: demoArguments,
                    command: command,
                    timeout: timeout
                )
            }
        }

        guard binaryPath != "" else {
            return AccountCommandOutput(
                status: 255,
                stdout: "",
                stderr: KwtSSHLeaseError.helperUnavailable.localizedDescription
            )
        }
        let executable = binaryPath ?? "/usr/bin/env"
        var arguments = binaryPath == nil ? ["kwt"] : []
        arguments += [
            "ssh", "exec", "--quiet", "--json",
            "--host-key-policy", "strict",
        ]
        if let expectedRouteIdentity {
            arguments += ["--route-identity", expectedRouteIdentity]
        }
        if let user = host.user {
            arguments += ["--user", user]
        }
        if let port = host.port {
            arguments += ["--port", String(port)]
        }
        arguments += [
            host.hostname,
            "--",
            AccountCommandRunner.remoteLoginCommand(
                host: host,
                command: command
            ),
        ]

        let commandArguments = arguments
        let output = await Self.runDetached {
            runner(executable, commandArguments, timeout)
        }
        return Self.normalizeKwtFailure(output)
    }

    private static func runDetached(
        _ operation: @escaping @Sendable () -> AccountCommandOutput
    ) async -> AccountCommandOutput {
        let output = await BlockingTask.run(operation)
        guard !Task.isCancelled else {
            return AccountCommandOutput(
                status: AccountCommandRunner.cancelledStatus,
                stdout: "",
                stderr: ""
            )
        }
        return output
    }

    private static func normalizeKwtFailure(
        _ output: AccountCommandOutput
    ) -> AccountCommandOutput {
        guard output.status != 0,
              let envelope = try? JSONDecoder().decode(
                  KwtSSHCommandErrorEnvelope.self,
                  from: Data(output.stdout.utf8)
              ),
              envelope.error.code.hasPrefix("ssh_")
        else { return output }
        let marker = SSHConnectionArgumentsSnapshot.failureMarker
            + envelope.error.code
            + "\n"
        let diagnostic = output.stderr.isEmpty
            ? envelope.error.message + "\n"
            : output.stderr
        return AccountCommandOutput(
            status: 255,
            stdout: "",
            stderr: marker + diagnostic
        )
    }
}

private struct KwtSSHCommandErrorEnvelope: Decodable {
    struct Failure: Decodable {
        let code: String
        let message: String
    }

    let error: Failure
}
