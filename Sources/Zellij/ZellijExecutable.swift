import Foundation

public enum ZellijEnvironment {
    public static let controlVariables = [
        "ZELLIJ",
        "ZELLIJ_PANE_ID",
        "ZELLIJ_SESSION_NAME",
    ]

    public static var unsetCommand: String {
        "unset " + controlVariables.joined(separator: " ")
    }
}

public enum ZellijExecutableResult: Equatable, Sendable {
    case available(String)
    case unavailable
    case failure(ZellijCommandError)
}

public enum ZellijExecutable {
    public static let marker = "GHOSTHUB_ZELLIJ_PATH"

    public static func command() -> String {
        [
            ZellijEnvironment.unsetCommand,
            "ghosthub_zellij_path=$(command -v zellij) || exit 127",
            "[ -n \"$ghosthub_zellij_path\" ] || exit 127",
            "case \"$ghosthub_zellij_path\" in /*) ;; *) exit 127 ;; esac",
            "[ -x \"$ghosthub_zellij_path\" ] || exit 127",
            "printf '%s\\n%s\\n' '\(marker)' \"$ghosthub_zellij_path\"",
        ].joined(separator: "; ")
    }

    public static func parse(
        status: Int32,
        stdout: String,
        stderr: String
    ) -> ZellijExecutableResult {
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
              lines.indices.contains(markerIndex + 1)
        else { return .unavailable }
        let path = lines[markerIndex + 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return .unavailable }
        return .available(path)
    }
}
