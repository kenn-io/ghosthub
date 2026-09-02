import GhosthubTmux
import GhosthubTransport

struct TmuxAttachedClientIdentity: Hashable, Sendable {
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

enum TmuxAttachedClientGuard {
    enum Scope {
        case client
        case pane
    }

    static func command(
        tmuxPath: String,
        socketName: String?,
        expectedClient: TmuxAttachedClientIdentity,
        marker: String,
        hookIndex: Int,
        action: String,
        scope: Scope = .pane
    ) -> String {
        let tmux = tmuxCommand(tmuxPath: tmuxPath, socketName: socketName)
        let hookName = "after-refresh-client[\(hookIndex)]"
        let clientIdentity = "#{&&:"
            + "#{==:#{client_pid},\(expectedClient.clientPID)},"
            + "#{&&:"
            + "#{==:#{client_created},\(expectedClient.clientCreatedAt)},"
            + "#{==:#{client_tty},\(expectedClient.clientTTY)}}}"
        let exactClient = "#{==:#{L:#{?\(clientIdentity),1,}},1}"
        let targetCondition: String
        switch scope {
        case .client:
            targetCondition = exactClient
        case .pane:
            targetCondition = "#{&&:\(exactClient),"
                + "#{==:#{pane_id},\(expectedClient.paneID)}}"
        }
        let condition = "#{&&:"
            + expectedClient.sessionIdentity.formatCondition
            + ",\(targetCondition)}"
        let guardedAction = [
            "if-shell", "-F", condition,
            action,
            "display-message -p " + shellQuotedCommandArgument(marker),
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        let hookBody = guardedHookBody(
            hookName: hookName,
            marker: marker,
            action: guardedAction
        )
        let queue = tmux + " " + [
            "set-hook", "-g", hookName, hookBody, ";",
            "refresh-client", "-t", expectedClient.clientTTY,
            marker, ";",
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
        return arguments.map(shellQuotedCommandArgument).joined(separator: " ")
    }

    private static func tmuxCommand(
        tmuxPath: String,
        socketName: String?
    ) -> String {
        var arguments = [tmuxPath]
        if let socketName, !socketName.isEmpty {
            arguments += ["-L", socketName]
        }
        return arguments.map(shellQuotedCommandArgument).joined(separator: " ")
    }

    private static func guardedHookBody(
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
}
