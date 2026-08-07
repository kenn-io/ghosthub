import Foundation
import GhosthubTerminalSupport
import GhosthubTmux

struct TmuxPaneSplitTarget: Sendable {
    var host: TmuxHost
    var tmuxPath: String
    var sessionName: String
    var socketName: String?
    var sshConnectionArguments: [String]
    var expectedIdentity: TmuxSessionIdentity?
    var clientToken: String?
    var expectedClient: TmuxPaneSplitClientIdentity?
}

struct TmuxPaneSplitClientIdentity: Hashable, Sendable {
    var serverPID: String
    var clientPID: String
    var clientCreatedAt: String
    var clientTTY: String
    var sessionID: String
    var sessionCreatedAt: String
    var paneID: String

    var sessionIdentity: TmuxSessionIdentity {
        TmuxSessionIdentity(
            serverPID: serverPID,
            sessionID: sessionID,
            createdAt: sessionCreatedAt
        )
    }

    func matchesClient(_ other: Self) -> Bool {
        serverPID == other.serverPID
            && clientPID == other.clientPID
            && clientCreatedAt == other.clientCreatedAt
            && clientTTY == other.clientTTY
            && sessionID == other.sessionID
            && sessionCreatedAt == other.sessionCreatedAt
    }

}

struct TmuxPaneSplitFailure: Error, Equatable, LocalizedError, Sendable {
    var host: String
    var sessionName: String
    var status: Int32
    var diagnostic: String

    var errorDescription: String? {
        var description =
            "tmux could not split pane in “\(sessionName)” on \(host) "
                + "(status \(status))."
        if !diagnostic.isEmpty {
            description += " \(diagnostic)"
        }
        return description
    }
}

struct TmuxPaneSplitter: Sendable {
    private static let clientIdentityMarker =
        "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY\t"
    private static let identityMismatchMarker =
        "GHOSTHUB_TMUX_SPLIT_IDENTITY_MISMATCH"
    typealias Runner = @Sendable (
        TmuxHost,
        [String],
        String
    ) -> (status: Int32, diagnostic: String)

    private let runner: Runner

    init(runner: Runner? = nil) {
        self.runner = runner ?? Self.run
    }

    static func supportsPaneSplitting(
        version: String,
        host: TmuxHost
    ) -> Bool {
        guard platform(for: host) == .posix else { return false }
        let fields = version.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[0] == "tmux" else { return false }
        let components = fields[1].split(separator: ".", maxSplits: 1)
        guard components.count == 2,
              let major = Int(components[0]),
              let minor = Int(components[1].prefix(while: \.isNumber))
        else { return false }
        return major > 3 || (major == 3 && minor >= 4)
    }

    func split(
        _ shortcut: TerminalTmuxSplitShortcut,
        target: TmuxPaneSplitTarget
    ) async -> TmuxPaneSplitFailure? {
        guard Self.platform(for: target.host) == .posix,
              let expectedClient = target.expectedClient
        else {
            return TmuxPaneSplitFailure(
                host: target.host.displayName,
                sessionName: target.sessionName,
                status: 75,
                diagnostic: "The attached tmux client identity is unavailable."
            )
        }
        let mismatchMarker = Self.identityMismatchMarker
            + "_\(UUID().uuidString)"
        let hookIndex = Int.random(in: 1_000_000_000 ... 2_000_000_000)
        let command = Self.command(
            tmuxPath: target.tmuxPath,
            socketName: target.socketName,
            shortcut: shortcut,
            expectedClient: expectedClient,
            mismatchMarker: mismatchMarker,
            hookIndex: hookIndex
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
        if Task.isCancelled {
            let cleanupCommand = Self.cleanupCommand(
                tmuxPath: target.tmuxPath,
                socketName: target.socketName,
                hookIndex: hookIndex
            )
            let cleanupTask = Task.detached(priority: .userInitiated) {
                runner(
                    target.host,
                    target.sshConnectionArguments,
                    cleanupCommand
                )
            }
            _ = await cleanupTask.value
            return nil
        }
        if result.diagnostic.split(whereSeparator: \.isNewline)
            .contains(Substring(mismatchMarker)) {
            return TmuxPaneSplitFailure(
                host: target.host.displayName,
                sessionName: target.sessionName,
                status: 75,
                diagnostic: "The attached tmux session changed."
            )
        }
        if result.status != 0,
           Self.normalizedDiagnostic(result.diagnostic)
           .hasPrefix("can't find client:") {
            return TmuxPaneSplitFailure(
                host: target.host.displayName,
                sessionName: target.sessionName,
                status: 75,
                diagnostic: "The attached tmux session changed."
            )
        }
        guard result.status != 0 else { return nil }
        return TmuxPaneSplitFailure(
            host: target.host.displayName,
            sessionName: target.sessionName,
            status: result.status,
            diagnostic: Self.normalizedDiagnostic(result.diagnostic)
        )
    }

    static func command(
        tmuxPath: String,
        socketName: String?,
        shortcut: TerminalTmuxSplitShortcut,
        expectedClient: TmuxPaneSplitClientIdentity,
        mismatchMarker: String,
        hookIndex: Int
    ) -> String {
        var arguments = [tmuxPath]
        if let socketName, !socketName.isEmpty {
            arguments += ["-L", socketName]
        }
        let tmux = arguments.map(shellQuotedCommandArgument)
            .joined(separator: " ")
        let hookName = "after-refresh-client[\(hookIndex)]"
        let mutation = [
            "split-window",
            shortcut == .right ? "-h" : "-v",
            "-t", expectedClient.paneID,
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        let clientIdentity = "#{&&:"
            + "#{==:#{client_pid},\(expectedClient.clientPID)},"
            + "#{&&:"
            + "#{==:#{client_created},\(expectedClient.clientCreatedAt)},"
            + "#{==:#{client_tty},\(expectedClient.clientTTY)}}}"
        let exactClient = "#{==:#{L:#{?\(clientIdentity),1,}},1}"
        let condition = "#{&&:"
            + expectedClient.sessionIdentity.formatCondition
            + ",#{&&:\(exactClient),"
            + "#{&&:#{==:#{pane_id},\(expectedClient.paneID)},"
            + "#{==:#{hook_argument_0},\(mismatchMarker)}}}}"
        let split = [
            "if-shell", "-F", condition,
            mutation,
            "display-message -p "
                + shellQuotedCommandArgument(mismatchMarker),
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        let guardedMutation = guardedHookBody(
            hookName: hookName,
            marker: mismatchMarker,
            action: split
        )
        let queue = tmux + " " + [
            "set-hook", "-g", hookName, guardedMutation, ";",
            "refresh-client", "-t", expectedClient.clientTTY,
            mismatchMarker, ";",
            "set-hook", "-gu", hookName,
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        let cleanup = cleanupCommand(
            tmuxPath: tmuxPath,
            socketName: socketName,
            hookIndex: hookIndex
        )
        return queue + "; ghosthub_status=$?; "
            + cleanup + " >/dev/null 2>&1; exit \"$ghosthub_status\""
    }

    static func cleanupCommand(
        tmuxPath: String,
        socketName: String?,
        hookIndex: Int
    ) -> String {
        var arguments = [tmuxPath]
        if let socketName, !socketName.isEmpty {
            arguments += ["-L", socketName]
        }
        arguments += [
            "set-hook", "-gu", "after-refresh-client[\(hookIndex)]",
        ]
        return arguments.map(shellQuotedCommandArgument)
            .joined(separator: " ")
    }

    static func guardedHookBody(
        hookName: String,
        marker: String,
        action: String
    ) -> String {
        let markerCondition = "#{==:#{hook_argument_0},\(marker)}"
        let removeHook = [
            "set-hook", "-gu", hookName,
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        return [
            "if-shell", "-F", markerCondition,
            removeHook + " ; " + action,
            "",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
    }

    func clientIdentity(
        target: TmuxPaneSplitTarget
    ) async -> Result<TmuxPaneSplitClientIdentity, TmuxPaneSplitFailure> {
        guard let clientToken = target.clientToken else {
            return .failure(clientIdentityUnavailable(target: target))
        }
        let command = Self.clientIdentityCommand(
            tmuxPath: target.tmuxPath,
            socketName: target.socketName,
            clientToken: clientToken,
            platform: Self.platform(for: target.host)
        )
        let result = await run(command: command, target: target)
        guard result.status == 0 else {
            return .failure(TmuxPaneSplitFailure(
                host: target.host.displayName,
                sessionName: target.sessionName,
                status: result.status,
                diagnostic: Self.normalizedDiagnostic(result.diagnostic)
            ))
        }
        guard let client = Self.parseClientIdentity(result.diagnostic) else {
            return .failure(clientIdentityUnavailable(target: target))
        }
        guard target.expectedIdentity == nil
            || client.sessionIdentity == target.expectedIdentity
        else {
            return .failure(TmuxPaneSplitFailure(
                host: target.host.displayName,
                sessionName: target.sessionName,
                status: 75,
                diagnostic: "The attached tmux session changed."
            ))
        }
        return .success(client)
    }

    private func run(
        command: String,
        target: TmuxPaneSplitTarget
    ) async -> (status: Int32, diagnostic: String) {
        let runner = runner
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else {
                return (status: Int32(0), diagnostic: "")
            }
            return runner(target.host, target.sshConnectionArguments, command)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func clientIdentityCommand(
        tmuxPath: String,
        socketName: String?,
        clientToken: String,
        platform: SSHHostInfo.Platform
    ) -> String {
        guard platform == .posix,
              !clientToken.isEmpty,
              clientToken.utf8.allSatisfy({ byte in
                  byte == 45 || byte >= 48 && byte <= 57
                      || byte >= 65 && byte <= 90
                      || byte >= 97 && byte <= 122
              })
        else { return "exit 75" }
        var arguments = [tmuxPath]
        if let socketName, !socketName.isEmpty {
            arguments += ["-L", socketName]
        }
        let tmux = arguments.map(shellQuotedCommandArgument).joined(separator: " ")
        var identityArguments = ["list-clients"]
        identityArguments += [
            "-F",
            "#{pid}\t#{client_pid}\t#{client_created}"
                + "\t#{client_tty}\t#{session_id}\t#{session_created}"
                + "\t#{pane_id}",
        ]
        let identityProbe = tmux + " "
            + identityArguments.map(shellQuotedCommandArgument)
            .joined(separator: " ")
        let identityFilter =
            "while IFS=\"$(printf '\\t')\" read -r "
                + "ghosthub_identity_server_pid ghosthub_identity_client_pid "
                + "ghosthub_identity_client_created ghosthub_identity_tty "
                + "ghosthub_identity_session_id ghosthub_identity_session_created "
                + "ghosthub_identity_pane_id; "
                + "do [ \"$ghosthub_identity_tty\" = \"$ghosthub_client_tty\" ] "
                + "|| continue; printf "
                + "'%s%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "
                + "\(shellQuotedCommandArgument(clientIdentityMarker)) "
                + "\"$ghosthub_identity_server_pid\" "
                + "\"$ghosthub_identity_client_pid\" "
                + "\"$ghosthub_identity_client_created\" "
                + "\"$ghosthub_identity_tty\" "
                + "\"$ghosthub_identity_session_id\" "
                + "\"$ghosthub_identity_session_created\" "
                + "\"$ghosthub_identity_pane_id\"; break; done"
        let path = "\"$HOME/.ghosthub/tmux-clients/\(clientToken)\""
        return "ghosthub_client_tty=; "
            + "for ghosthub_client_probe_delay in "
            + "0.01 0.02 0.04 0.08 0.16 0.32 0.64 1 1 1 1; do "
            + "ghosthub_client_tty=; "
            + "IFS= read -r ghosthub_client_tty < \(path) 2>/dev/null || :; "
            + "if [ -n \"$ghosthub_client_tty\" ]; then "
            + "ghosthub_client_identity=$(\(identityProbe) 2>/dev/null "
            + "| \(identityFilter)) "
            + "&& [ -n \"$ghosthub_client_identity\" ] "
            + "&& { printf '%s\\n' \"$ghosthub_client_identity\"; break; }; "
            + "fi; sleep \"$ghosthub_client_probe_delay\"; done"
    }

    private static func parseClientIdentity(
        _ output: String
    ) -> TmuxPaneSplitClientIdentity? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { $0.hasPrefix(clientIdentityMarker) })
        else { return nil }
        let fields = line.dropFirst(clientIdentityMarker.count).split(
            separator: "\t", maxSplits: 6,
            omittingEmptySubsequences: false
        )
        guard fields.count == 7,
              isNumeric(fields[0]),
              isNumeric(fields[1]),
              isNumeric(fields[2]),
              fields[3].first == "/",
              fields[4].first == "$",
              isNumeric(fields[4].dropFirst()),
              isNumeric(fields[5]),
              fields[6].first == "%",
              isNumeric(fields[6].dropFirst())
        else { return nil }
        return TmuxPaneSplitClientIdentity(
            serverPID: String(fields[0]),
            clientPID: String(fields[1]),
            clientCreatedAt: String(fields[2]),
            clientTTY: String(fields[3]),
            sessionID: String(fields[4]),
            sessionCreatedAt: String(fields[5]),
            paneID: String(fields[6])
        )
    }

    private func clientIdentityUnavailable(
        target: TmuxPaneSplitTarget
    ) -> TmuxPaneSplitFailure {
        TmuxPaneSplitFailure(
            host: target.host.displayName,
            sessionName: target.sessionName,
            status: 75,
            diagnostic: "The attached tmux client identity is unavailable."
        )
    }

    private static func isNumeric<S: StringProtocol>(_ value: S) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func run(
        host: TmuxHost,
        sshConnectionArguments: [String],
        command: String
    ) -> (status: Int32, diagnostic: String) {
        switch host {
        case .local:
            let result = TmuxBinaryResolver.runLoginShell(
                shell: TmuxBinaryResolver.loginShell(),
                command: command,
                timeout: 15,
                captureStandardError: true
            )
            return (result.status, result.stdout)
        case let .ssh(info):
            var arguments = [
                "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            ]
            arguments += sshConnectionArguments
            if let port = info.port {
                arguments += ["-p", String(port)]
            }
            let destination = info.user.map { "\($0)@\(info.hostname)" }
                ?? info.hostname
            arguments += [
                "--",
                destination,
                TmuxBinaryResolver.remoteLoginCommand(
                    host: info,
                    command: command
                ),
            ]
            let result = TmuxBinaryResolver.runProcessInLoginShell(
                executable: "/usr/bin/ssh",
                arguments: arguments,
                timeout: 15,
                captureStandardError: true
            )
            return (result.status, result.stdout)
        }
    }

    private static func normalizedDiagnostic(_ diagnostic: String) -> String {
        let normalized = diagnostic
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(normalized.prefix(400))
    }

    private static func platform(
        for host: TmuxHost
    ) -> SSHHostInfo.Platform {
        switch host {
        case .local:
            return .posix
        case let .ssh(info):
            return info.platform
        }
    }

}
