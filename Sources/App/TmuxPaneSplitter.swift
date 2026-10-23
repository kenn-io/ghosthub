import Foundation
import GhosthubTerminalSupport
import GhosthubTmux
import GhosthubTransport

struct TmuxPaneSplitTarget: Sendable {
    var host: CommandHost
    var tmuxPath: String
    var sessionName: String
    var socketName: String?
    var sshConnectionArguments: [String]
    var expectedIdentity: TmuxSessionIdentity?
    var clientToken: String?
    var clientTTYDirectory: String?
    var expectedClient: TmuxAttachedClientIdentity?
}

struct TmuxPaneSplitFailure: Error, Equatable, LocalizedError, Sendable {
    var host: String
    var sessionName: String
    var status: Int32
    var diagnostic: String
    var kind: Kind = .terminal

    enum Kind: Equatable, Sendable {
        case terminal
        case atomicGuardChanged
    }

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
    private static let sizingMismatchMarker =
        "GHOSTHUB_TMUX_CLIENT_SIZING_MISMATCH"
    private static let detachRefusedMarker =
        "GHOSTHUB_TMUX_CLIENT_DETACH_REFUSED"
    typealias Runner = @Sendable (
        CommandHost,
        [String],
        String
    ) -> (status: Int32, diagnostic: String)

    private let runner: Runner

    init(runner: Runner? = nil) {
        self.runner = runner ?? Self.run
    }

    static func supportsClientIdentity(host: CommandHost) -> Bool {
        platform(for: host) == .posix
    }

    static func supportsPaneSplitting(
        version: String,
        host: CommandHost
    ) -> Bool {
        supportsExactClientTargeting(version: version, host: host)
    }

    static func supportsClientSizing(
        version: String,
        host: CommandHost
    ) -> Bool {
        supportsExactClientTargeting(version: version, host: host)
    }

    private static func supportsExactClientTargeting(
        version: String,
        host: CommandHost
    ) -> Bool {
        guard platform(for: host) == .posix else { return false }
        guard let version = TmuxVersion(output: version) else { return false }
        return version >= .minimumFind
    }

    func split(
        _ shortcut: TerminalPaneSplitShortcut,
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
            let cleanupCommand = TmuxAttachedClientGuard.cleanupCommand(
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
                diagnostic: "The attached tmux session changed.",
                kind: .atomicGuardChanged
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

    func enableSizing(
        target: TmuxPaneSplitTarget
    ) async -> TmuxPaneSplitFailure? {
        await setIgnoreSize(false, target: target)
    }

    func disableSizing(
        target: TmuxPaneSplitTarget
    ) async -> TmuxPaneSplitFailure? {
        await setIgnoreSize(true, target: target)
    }

    private func setIgnoreSize(
        _ ignoresClientSize: Bool,
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
        let mismatchMarker = Self.sizingMismatchMarker
            + "_\(UUID().uuidString)"
        let hookIndex = Int.random(in: 1_000_000_000 ... 2_000_000_000)
        let command = Self.sizingCommand(
            tmuxPath: target.tmuxPath,
            socketName: target.socketName,
            expectedClient: expectedClient,
            ignoresClientSize: ignoresClientSize,
            mismatchMarker: mismatchMarker,
            hookIndex: hookIndex
        )
        guard let result = await runGuarded(
            command: command,
            hookIndex: hookIndex,
            target: target
        ) else { return nil }
        if result.diagnostic.split(whereSeparator: \.isNewline)
            .contains(Substring(mismatchMarker)) {
            return TmuxPaneSplitFailure(
                host: target.host.displayName,
                sessionName: target.sessionName,
                status: 75,
                diagnostic: "The attached tmux session changed.",
                kind: .atomicGuardChanged
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

    /// Detaches `duplicate` only while it and the target's client are both
    /// still attached to the target client's session. tmux checks and
    /// detaches in one command queue, so the detach never takes any
    /// session's last client.
    func detachClient(
        _ duplicate: TmuxAttachedClientIdentity,
        keeping target: TmuxPaneSplitTarget
    ) async -> Bool {
        guard Self.platform(for: target.host) == .posix,
              let keeper = target.expectedClient
        else { return false }
        let marker = Self.detachRefusedMarker + "_\(UUID().uuidString)"
        let hookIndex = Int.random(in: 1_000_000_000 ... 2_000_000_000)
        let command = Self.detachCommand(
            tmuxPath: target.tmuxPath,
            socketName: target.socketName,
            keeper: keeper,
            duplicate: duplicate,
            marker: marker,
            hookIndex: hookIndex
        )
        return await runDetach(
            command: command,
            hookIndex: hookIndex,
            marker: marker,
            target: target
        )
    }

    /// Detaches the target's client only while the session it is on now
    /// has another client. tmux may have moved the client off the session
    /// it last reported, so the check follows the client, not a session.
    func detachClientSharingSession(
        target: TmuxPaneSplitTarget
    ) async -> Bool {
        guard Self.platform(for: target.host) == .posix,
              let client = target.expectedClient
        else { return false }
        let marker = Self.detachRefusedMarker + "_\(UUID().uuidString)"
        let hookIndex = Int.random(in: 1_000_000_000 ... 2_000_000_000)
        let command = Self.sharedSessionDetachCommand(
            tmuxPath: target.tmuxPath,
            socketName: target.socketName,
            client: client,
            marker: marker,
            hookIndex: hookIndex
        )
        return await runDetach(
            command: command,
            hookIndex: hookIndex,
            marker: marker,
            target: target
        )
    }

    private func runDetach(
        command: String,
        hookIndex: Int,
        marker: String,
        target: TmuxPaneSplitTarget
    ) async -> Bool {
        guard let result = await runGuarded(
            command: command,
            hookIndex: hookIndex,
            target: target
        ) else { return false }
        return result.status == 0
            && !result.diagnostic.split(whereSeparator: \.isNewline)
            .contains(Substring(marker))
    }

    static func sharedSessionDetachCommand(
        tmuxPath: String,
        socketName: String?,
        client: TmuxAttachedClientIdentity,
        marker: String,
        hookIndex: Int
    ) -> String {
        // The guard runs in the client's own context, so `session_attached`
        // counts the clients of the session it is on now.
        let detach = [
            "if-shell", "-F", "#{>:#{session_attached},1}",
            ["detach-client", "-t", client.clientTTY]
                .map(shellQuotedCommandArgument).joined(separator: " "),
            "display-message -p " + shellQuotedCommandArgument(marker),
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        return TmuxAttachedClientGuard.command(
            tmuxPath: tmuxPath,
            socketName: socketName,
            expectedClient: client,
            marker: marker,
            hookIndex: hookIndex,
            action: detach,
            scope: .anySession
        )
    }

    static func detachCommand(
        tmuxPath: String,
        socketName: String?,
        keeper: TmuxAttachedClientIdentity,
        duplicate: TmuxAttachedClientIdentity,
        marker: String,
        hookIndex: Int
    ) -> String {
        // The guard runs in the kept client's context, so inside the client
        // loop `session_name` is the kept client's session and
        // `client_session` is the looped client's. Names are unique per
        // server.
        let duplicateClient = "#{&&:"
            + "#{==:#{client_pid},\(duplicate.clientPID)},"
            + "#{&&:"
            + "#{==:#{client_created},\(duplicate.clientCreatedAt)},"
            + "#{&&:"
            + "#{==:#{client_tty},\(duplicate.clientTTY)},"
            + "#{==:#{client_session},#{session_name}}}}}"
        let detach = [
            "if-shell", "-F", "#{==:#{L:#{?\(duplicateClient),1,}},1}",
            ["detach-client", "-t", duplicate.clientTTY]
                .map(shellQuotedCommandArgument).joined(separator: " "),
            "display-message -p " + shellQuotedCommandArgument(marker),
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        return TmuxAttachedClientGuard.command(
            tmuxPath: tmuxPath,
            socketName: socketName,
            expectedClient: keeper,
            marker: marker,
            hookIndex: hookIndex,
            action: detach,
            scope: .client
        )
    }

    static func command(
        tmuxPath: String,
        socketName: String?,
        shortcut: TerminalPaneSplitShortcut,
        expectedClient: TmuxAttachedClientIdentity,
        mismatchMarker: String,
        hookIndex: Int
    ) -> String {
        let mutation = [
            "split-window",
            shortcut == .right ? "-h" : "-v",
            "-t", expectedClient.paneID,
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        return TmuxAttachedClientGuard.command(
            tmuxPath: tmuxPath,
            socketName: socketName,
            expectedClient: expectedClient,
            marker: mismatchMarker,
            hookIndex: hookIndex,
            action: mutation
        )
    }

    static func enableSizingCommand(
        tmuxPath: String,
        socketName: String?,
        expectedClient: TmuxAttachedClientIdentity,
        mismatchMarker: String,
        hookIndex: Int
    ) -> String {
        sizingCommand(
            tmuxPath: tmuxPath,
            socketName: socketName,
            expectedClient: expectedClient,
            ignoresClientSize: false,
            mismatchMarker: mismatchMarker,
            hookIndex: hookIndex
        )
    }

    static func sizingCommand(
        tmuxPath: String,
        socketName: String?,
        expectedClient: TmuxAttachedClientIdentity,
        ignoresClientSize: Bool,
        mismatchMarker: String,
        hookIndex: Int
    ) -> String {
        let updateSizing = [
            "refresh-client", "-t", expectedClient.clientTTY,
            "-f", ignoresClientSize ? "ignore-size" : "!ignore-size",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        return TmuxAttachedClientGuard.command(
            tmuxPath: tmuxPath,
            socketName: socketName,
            expectedClient: expectedClient,
            marker: mismatchMarker,
            hookIndex: hookIndex,
            action: updateSizing,
            scope: .client
        )
    }

    func clientIdentity(
        target: TmuxPaneSplitTarget,
        priority: TaskPriority = .userInitiated
    ) async -> Result<TmuxAttachedClientIdentity, TmuxPaneSplitFailure> {
        guard let clientToken = target.clientToken else {
            return .failure(clientIdentityUnavailable(target: target))
        }
        let command = Self.clientIdentityCommand(
            tmuxPath: target.tmuxPath,
            socketName: target.socketName,
            clientToken: clientToken,
            clientTTYDirectory: target.clientTTYDirectory,
            platform: Self.platform(for: target.host)
        )
        let result = await run(
            command: command,
            target: target,
            priority: priority
        )
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

    /// Runs a `TmuxAttachedClientGuard` command and returns nil when the task
    /// is cancelled, after removing the hook the cancelled command set.
    private func runGuarded(
        command: String,
        hookIndex: Int,
        target: TmuxPaneSplitTarget
    ) async -> (status: Int32, diagnostic: String)? {
        let result = await run(command: command, target: target)
        guard Task.isCancelled else { return result }
        let cleanup = TmuxAttachedClientGuard.cleanupCommand(
            tmuxPath: target.tmuxPath,
            socketName: target.socketName,
            hookIndex: hookIndex
        )
        let runner = runner
        let cleanupTask = Task.detached(priority: .userInitiated) {
            runner(
                target.host,
                target.sshConnectionArguments,
                cleanup
            )
        }
        _ = await cleanupTask.value
        return nil
    }

    private func run(
        command: String,
        target: TmuxPaneSplitTarget,
        priority: TaskPriority = .userInitiated
    ) async -> (status: Int32, diagnostic: String) {
        let runner = runner
        let task = Task.detached(priority: priority) {
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
        clientTTYDirectory: String?,
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
        var arguments = TmuxSocketEnvironment.commandPrefix(socketName: socketName) + [tmuxPath]
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
        let path: String
        if let clientTTYDirectory {
            let separator = clientTTYDirectory.hasSuffix("/") ? "" : "/"
            path = shellQuotedCommandArgument(
                clientTTYDirectory + separator + clientToken
            )
        } else {
            path = "\"$HOME/.ghosthub/tmux-clients/\(clientToken)\""
        }
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
    ) -> TmuxAttachedClientIdentity? {
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
        return TmuxAttachedClientIdentity(
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
        host: CommandHost,
        sshConnectionArguments: [String],
        command: String
    ) -> (status: Int32, diagnostic: String) {
        switch host {
        case .local:
            let result = AccountCommandRunner.runLoginShell(
                shell: AccountCommandRunner.loginShell(),
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
                AccountCommandRunner.remoteLoginCommand(
                    host: info,
                    command: command
                ),
            ]
            let result = AccountCommandRunner.runProcessInLoginShell(
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
        for host: CommandHost
    ) -> SSHHostInfo.Platform {
        switch host {
        case .local:
            return .posix
        case let .ssh(info):
            return info.platform
        }
    }

}
