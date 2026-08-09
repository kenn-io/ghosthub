import Foundation
import GhosthubHerdr
import GhosthubTerminalSupport
import GhosthubTransport

struct HerdrPaneSplitTarget: Sendable {
    var host: CommandHost
    var herdrPath: String
    var sessionName: String
    var socketPath: String
    var sshConnectionArguments: [String]
}

struct HerdrPaneSplitFailure: Error, Equatable, LocalizedError, Sendable {
    var host: String
    var sessionName: String
    var status: Int32
    var diagnostic: String

    var errorDescription: String? {
        var value = "Herdr could not split the active pane in "
            + "“\(sessionName)” on \(host) (status \(status))."
        if !diagnostic.isEmpty {
            value += " \(diagnostic)"
        }
        return value
    }
}

struct HerdrPaneSplitter: Sendable {
    typealias Runner = @Sendable (
        CommandHost,
        [String],
        String
    ) -> (status: Int32, diagnostic: String)

    private let runner: Runner

    init(runner: Runner? = nil) {
        self.runner = runner ?? Self.run
    }

    func split(
        _ shortcut: TerminalPaneSplitShortcut,
        target: HerdrPaneSplitTarget
    ) async -> HerdrPaneSplitFailure? {
        let command = Self.command(
            herdrPath: target.herdrPath,
            socketPath: target.socketPath,
            shortcut: shortcut
        )
        let runner = runner
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else {
                return (status: Int32(0), diagnostic: "")
            }
            return runner(
                target.host,
                target.sshConnectionArguments,
                command
            )
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, result.status != 0 else { return nil }
        return HerdrPaneSplitFailure(
            host: target.host.displayName,
            sessionName: target.sessionName,
            status: result.status,
            diagnostic: Self.normalizedDiagnostic(result.diagnostic)
        )
    }

    static func command(
        herdrPath: String,
        socketPath: String,
        shortcut: TerminalPaneSplitShortcut
    ) -> String {
        let direction = shortcut == .right ? "right" : "down"
        let invocation = [
            herdrPath,
            "pane",
            "split",
            "--direction",
            direction,
            "--focus",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        return [
            HerdrEnvironment.unsetCommand,
            "export HERDR_SOCKET_PATH="
                + shellQuotedCommandArgument(socketPath),
            "exec \(invocation)",
        ].joined(separator: "; ")
    }

    private static func run(
        host: CommandHost,
        sshConnectionArguments: [String],
        command: String
    ) -> (status: Int32, diagnostic: String) {
        let runner = AccountCommandRunner()
        let output: AccountCommandOutput
        switch host {
        case .local:
            output = runner.runLocalLoginShell(
                command: command,
                timeout: 15
            )
        case let .ssh(info):
            output = runner.runRemoteLoginShell(
                host: info,
                connectionArguments: sshConnectionArguments,
                command: command,
                timeout: 15
            )
        }
        return (output.status, output.stdout + output.stderr)
    }

    private static func normalizedDiagnostic(_ diagnostic: String) -> String {
        let normalized = diagnostic
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(normalized.prefix(400))
    }
}
