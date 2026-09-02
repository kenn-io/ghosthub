import Foundation
import GhosthubTransport

struct TmuxFindTarget: Sendable {
    let host: CommandHost
    let tmuxPath: String
    let tmuxVersion: TmuxVersion
    let sessionName: String
    let socketName: String?
    let sshConnectionArguments: [String]
    let expectedClient: TmuxAttachedClientIdentity
}

enum TmuxFindMutation: Equatable, Sendable {
    case search(String)
    case next
    case previous
    case cancel
}

enum TmuxFindState: Equatable, Sendable {
    case match(total: UInt?)
    case noMatch
}

struct TmuxFindFailure: Error, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case targetChanged
        case transport
        case command
        case malformedState
    }

    let kind: Kind
    let status: Int32
    let message: String
}

struct TmuxPaneFinder: Sendable {
    typealias Runner = @Sendable (
        CommandHost,
        [String],
        String
    ) -> (status: Int32, diagnostic: String)

    private let runner: Runner

    init(runner: Runner? = nil) {
        self.runner = runner ?? Self.run
    }

    func perform(
        _ mutation: TmuxFindMutation,
        target: TmuxFindTarget
    ) async -> Result<TmuxFindState?, TmuxFindFailure> {
        let guardMarker = "GHOSTHUB_TMUX_FIND_IDENTITY_MISMATCH_"
            + UUID().uuidString
        let stateMarker = "GHOSTHUB_TMUX_FIND_STATE_" + UUID().uuidString
        let hookIndex = Int.random(in: 1_000_000_000 ... 2_000_000_000)
        let rendered = Self.command(
            mutation,
            target: target,
            guardMarker: guardMarker,
            stateMarker: stateMarker,
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
                rendered
            )
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if Task.isCancelled {
            let cleanup = TmuxAttachedClientGuard.cleanupCommand(
                tmuxPath: target.tmuxPath,
                socketName: target.socketName,
                hookIndex: hookIndex
            )
            _ = await Task.detached(priority: .userInitiated) {
                runner(target.host, target.sshConnectionArguments, cleanup)
            }.value
            return .success(nil)
        }

        if result.diagnostic.split(whereSeparator: \.isNewline)
            .contains(Substring(guardMarker))
            || result.diagnostic.lowercased().contains("can't find client:") {
            return .failure(.init(
                kind: .targetChanged,
                status: 75,
                message: "The attached tmux session changed."
            ))
        }
        guard result.status == 0 else {
            if Self.isTransportFailure(
                status: result.status,
                host: target.host
            ) {
                return .failure(.init(
                    kind: .transport,
                    status: result.status,
                    message: "Find lost its connection to tmux."
                ))
            }
            return .failure(.init(
                kind: .command,
                status: result.status,
                message: "tmux could not search this pane."
            ))
        }
        guard mutation != .cancel else { return .success(nil) }
        guard let state = Self.parseState(
            result.diagnostic,
            marker: stateMarker,
            includesCount: target.tmuxVersion >= .searchCount
        ) else {
            return .failure(.init(
                kind: .malformedState,
                status: result.status,
                message: "tmux returned an invalid Find result."
            ))
        }
        return .success(state)
    }

    static func command(
        _ mutation: TmuxFindMutation,
        target: TmuxFindTarget,
        guardMarker: String,
        stateMarker: String,
        hookIndex: Int
    ) -> String {
        TmuxAttachedClientGuard.command(
            tmuxPath: target.tmuxPath,
            socketName: target.socketName,
            expectedClient: target.expectedClient,
            marker: guardMarker,
            hookIndex: hookIndex,
            action: action(
                mutation,
                target: target,
                stateMarker: stateMarker
            )
        )
    }

    static func action(
        _ mutation: TmuxFindMutation,
        target: TmuxFindTarget,
        stateMarker: String
    ) -> String {
        let pane = target.expectedClient.paneID
        var commands: [[String]]
        switch mutation {
        case let .search(query):
            var search = [
                "send-keys", "-t", pane, "-X", "search-backward-text",
            ]
            if target.tmuxVersion >= .copyModeOptionParsing {
                search.append("--")
            }
            search.append(query)
            commands = [
                ["copy-mode", "-t", pane],
                ["send-keys", "-t", pane, "-X", "history-bottom"],
                search,
            ]
        case .next:
            commands = [["send-keys", "-t", pane, "-X", "search-again"]]
        case .previous:
            commands = [["send-keys", "-t", pane, "-X", "search-reverse"]]
        case .cancel:
            commands = [["send-keys", "-t", pane, "-X", "cancel"]]
        }
        if mutation != .cancel {
            var format = stateMarker + "\t#{search_present}"
            if target.tmuxVersion >= .searchCount {
                format += "\t#{search_count}\t#{search_count_partial}"
            }
            commands.append(["display-message", "-p", "-t", pane, format])
        }
        return commands.map {
            $0.map(shellQuotedCommandArgument).joined(separator: " ")
        }.joined(separator: " ; ")
    }

    static func parseState(
        _ output: String,
        marker: String,
        includesCount: Bool
    ) -> TmuxFindState? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { $0.hasPrefix(marker + "\t") })
        else { return nil }
        let fields = line.split(
            separator: "\t",
            omittingEmptySubsequences: false
        )
        guard fields.count == (includesCount ? 4 : 2),
              fields[0] == Substring(marker)
        else { return nil }
        switch fields[1] {
        case "0":
            return .noMatch
        case "1":
            guard includesCount else { return .match(total: nil) }
            guard fields[3] == "0" else { return .match(total: nil) }
            return .match(total: UInt(fields[2]))
        default:
            return nil
        }
    }

    private static func isTransportFailure(
        status: Int32,
        host: CommandHost
    ) -> Bool {
        status == AccountCommandRunner.timedOutStatus
            || {
                if case .ssh = host {
                    return status == 255
                }
                return false
            }()
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
}
