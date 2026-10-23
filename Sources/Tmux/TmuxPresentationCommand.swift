import GhosthubTransport

/// Colors Ghosthub applies to tmux panes. Tmux otherwise answers OSC 10/11
/// queries from the first attached client, which can describe another
/// terminal's theme.
public struct TmuxPresentationStyle: Equatable, Sendable {
    public let foreground: String
    public let background: String

    public init(foreground: String, background: String) {
        self.foreground = foreground
        self.background = background
    }

    var tmuxStyle: String {
        "fg=\(foreground),bg=\(background)"
    }
}

public struct TmuxPresentationCommand: Equatable, Sendable {
    package static let identityMismatchMarker =
        "GHOSTHUB_TMUX_SESSION_IDENTITY_MISMATCH"

    public let sessionName: String
    public let socketName: String?
    public let style: TmuxPresentationStyle

    public init(
        sessionName: String,
        socketName: String?,
        style: TmuxPresentationStyle
    ) {
        self.sessionName = sessionName
        self.socketName = socketName
        self.style = style
    }

    /// Each mutation first checks the session identity through the session
    /// name, or through the session ID when `followsRename` is set, so a
    /// session renamed since its identity was read is still styled.
    public func applyCommand(
        tmuxPath: String,
        expectedIdentity: TmuxSessionIdentity,
        followsRename: Bool = false
    ) -> String {
        strictCommand(
            tmuxPath: tmuxPath,
            expectedIdentity: expectedIdentity,
            checkTarget: followsRename ? expectedIdentity.sessionID : target
        )
    }

    func appendingOptions(to arguments: [String]) -> [String] {
        var result = arguments
        for (option, value) in sessionOptions {
            result += [
                ";", "set-option", "-t", target, option, value,
            ]
        }
        for (option, value) in windowOptions {
            result += [
                ";", "set-option", "-w", "-t", target, option, value,
            ]
        }
        return result
    }

    /// Tmux interaction remains user-owned. These style resets only make tmux
    /// chrome and terminal default-color queries resolve through Ghosthub's
    /// current colors.
    func bestEffortCommand(tmuxPath: String) -> String {
        var commands = sessionOptions.map { option, value in
            let command = tmuxArguments(
                tmuxPath,
                "set-option", "-t", target, option, value
            ).map(shellQuotedCommandArgument).joined(separator: " ")
            return "\(command) >/dev/null 2>&1 || :"
        }
        let listWindows = tmuxArguments(
            tmuxPath,
            "list-windows", "-t", target, "-F", "#{window_id}"
        ).map(shellQuotedCommandArgument).joined(separator: " ")
        let setWindowOptions = windowOptions.map { option, value in
            let commandPrefix = tmuxArguments(
                tmuxPath,
                "set-option", "-w", "-t"
            ).map(shellQuotedCommandArgument).joined(separator: " ")
            return "\(commandPrefix) \"$ghosthub_window\" "
                + "\(shellQuotedCommandArgument(option)) "
                + "\(shellQuotedCommandArgument(value)) "
                + ">/dev/null 2>&1 || :"
        }.joined(separator: "; ")
        commands.append(
            "\(listWindows) 2>/dev/null | "
                + "while IFS= read -r ghosthub_window; do "
                + "\(setWindowOptions); done"
        )
        return commands.joined(separator: "; ")
    }

    private func strictCommand(
        tmuxPath: String,
        expectedIdentity: TmuxSessionIdentity,
        checkTarget: String
    ) -> String {
        var commands = sessionOptions.map { option, value in
            identityCheckedCommand(
                tmuxPath: tmuxPath,
                expectedIdentity: expectedIdentity,
                checkTarget: checkTarget,
                mutation: shellQuotedCommandArgument(tmuxCommand(
                    "set-option", "-t", expectedIdentity.sessionID,
                    option, value
                ))
            )
        }
        let listWindows = identityCheckedCommand(
            tmuxPath: tmuxPath,
            expectedIdentity: expectedIdentity,
            checkTarget: checkTarget,
            mutation: shellQuotedCommandArgument(tmuxCommand(
                "list-windows", "-t", expectedIdentity.sessionID,
                "-F", "#{window_id}"
            ))
        )
        commands.append("ghosthub_windows=\"$(\(listWindows))\"")
        let mismatch = shellQuotedCommandArgument(Self.identityMismatchMarker)
        commands.append(
            "if [ \"$ghosthub_windows\" = \(mismatch) ]; then "
                + "printf '%s\\n' \"$ghosthub_windows\"; exit 0; fi"
        )
        let setWindowOptions = windowOptions.map { option, value in
            // `if-shell -t` does not pass its target to the command it
            // runs, so the shell puts the window ID into the mutation.
            let mutation = shellQuotedCommandArgument(
                tmuxCommand("set-option", "-w", "-t") + " "
            ) + "\"$ghosthub_window\"" + shellQuotedCommandArgument(
                " " + tmuxCommand(option, value)
            )
            return identityCheckedCommand(
                tmuxPath: tmuxPath,
                expectedIdentity: expectedIdentity,
                checkTarget: checkTarget,
                shellTarget: "$ghosthub_window",
                mutation: mutation
            )
        }.joined(separator: " && ")
        commands.append(
            "for ghosthub_window in $ghosthub_windows; do { "
                + "\(setWindowOptions); } || exit $?; done"
        )
        return commands.joined(separator: " && ")
    }

    private func identityCheckedCommand(
        tmuxPath: String,
        expectedIdentity: TmuxSessionIdentity,
        checkTarget: String,
        shellTarget: String? = nil,
        // A shell word that expands to the tmux command to run.
        mutation: String
    ) -> String {
        let argumentsBeforeTarget = tmuxArguments(
            tmuxPath,
            "if-shell", "-F", "-t"
        ).map(shellQuotedCommandArgument).joined(separator: " ")
        let checkedTarget = if let shellTarget {
            "\"\(shellTarget)\""
        } else {
            shellQuotedCommandArgument(checkTarget)
        }
        let argumentsAfterTarget = [
            shellQuotedCommandArgument(expectedIdentity.formatCondition),
            mutation,
            shellQuotedCommandArgument(
                "display-message -p "
                    + shellQuotedCommandArgument(Self.identityMismatchMarker)
            ),
        ].joined(separator: " ")
        return "\(argumentsBeforeTarget) \(checkedTarget) \(argumentsAfterTarget)"
    }

    private func tmuxCommand(_ arguments: String...) -> String {
        arguments.map(shellQuotedCommandArgument).joined(separator: " ")
    }

    private var target: String {
        // A trailing colon makes tmux interpret `=name:` as an exact session
        // target instead of accepting a session-name prefix.
        "=\(sessionName):"
    }

    private var sessionOptions: [(String, String)] {
        [
            ("status-style", "reverse"),
            ("message-style", "reverse"),
            ("message-command-style", "reverse"),
        ]
    }

    private var windowOptions: [(String, String)] {
        [
            ("window-style", style.tmuxStyle),
            ("window-active-style", style.tmuxStyle),
        ]
    }

    private func tmuxArguments(
        _ tmuxPath: String,
        _ arguments: String...
    ) -> [String] {
        var result = TmuxSocketEnvironment.commandPrefix(socketName: socketName) + [tmuxPath]
        if let socketName, !socketName.isEmpty {
            result.append(contentsOf: ["-L", socketName])
        }
        return result + arguments
    }
}
