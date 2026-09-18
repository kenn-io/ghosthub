/// Kwt's canonical server ignores the account's socket-directory override.
/// Other named sockets, including legacy protected endpoints, retain it.
package enum TmuxSocketEnvironment {
    package static func commandPrefix(socketName: String?) -> [String] {
        socketName == "kwt" ? ["/usr/bin/env", "-u", "TMUX_TMPDIR"] : []
    }

    package static func powerShellPrelude(socketName: String?) -> String {
        socketName == "kwt" ? "$env:TMUX_TMPDIR = $null\n" : ""
    }
}
