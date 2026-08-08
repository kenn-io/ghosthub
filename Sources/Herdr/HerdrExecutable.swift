import Foundation

public enum HerdrEnvironment {
    public static let controlVariables = [
        "HERDR_ENV",
        "HERDR_SESSION",
        "HERDR_SOCKET_PATH",
        "HERDR_CLIENT_SOCKET_PATH",
        "HERDR_PANE_ID",
        "HERDR_TAB_ID",
        "HERDR_WORKSPACE_ID",
        "HERDR_BIN_PATH",
        "HERDR_ACTIVE_WORKSPACE_ID",
        "HERDR_ACTIVE_TAB_ID",
        "HERDR_ACTIVE_PANE_ID",
        "HERDR_ACTIVE_PANE_CWD",
    ]

    static var unsetCommand: String {
        "unset " + controlVariables.joined(separator: " ")
    }
}

public enum HerdrExecutableResult: Equatable, Sendable {
    case available(String)
    case unavailable
    case failure(HerdrCommandError)
}

public enum HerdrExecutable {
    public static let marker = "GHOSTHUB_HERDR_PATH"

    public static func command() -> String {
        [
            HerdrEnvironment.unsetCommand,
            "ghosthub_herdr_path=$(command -v herdr) || exit 127",
            "[ -n \"$ghosthub_herdr_path\" ] || exit 127",
            "case \"$ghosthub_herdr_path\" in /*) ;; *) exit 127 ;; esac",
            "[ -x \"$ghosthub_herdr_path\" ] || exit 127",
            "printf '%s\\n%s\\n' '\(marker)' \"$ghosthub_herdr_path\"",
        ].joined(separator: "; ")
    }

    public static func parse(
        status: Int32,
        stdout: String,
        stderr: String
    ) -> HerdrExecutableResult {
        if status == 127 {
            return .unavailable
        }
        guard status == 0 else {
            return .failure(.commandFailed(status: status, stderr: stderr))
        }

        let lines = stdout.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let markerIndex = lines.lastIndex(of: marker),
              lines.indices.contains(markerIndex + 1) else {
            return .unavailable
        }
        let path = lines[markerIndex + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else {
            return .unavailable
        }
        return .available(path)
    }
}
