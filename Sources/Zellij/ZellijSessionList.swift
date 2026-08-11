import Foundation
import GhosthubTransport

public enum ZellijDiscoveryResult: Equatable, Sendable {
    case available([String])
    case unavailable
    case failure(ZellijCommandError)
}

public enum ZellijSessionList {
    public static let marker = "GHOSTHUB_ZELLIJ_SESSIONS"
    public static let errorMarker = "GHOSTHUB_ZELLIJ_ERRORS"

    public static func command(zellijPath: String) -> String {
        let invocation = [zellijPath, "list-sessions", "--no-formatting"]
            .map(shellQuotedCommandArgument)
            .joined(separator: " ")
        return [
            "printf '\\n%s\\n' '\(marker)'",
            "printf '\\n%s\\n' '\(errorMarker)' >&2",
            "exec \(invocation)",
        ].joined(separator: "; ")
    }

    public static func parse(
        status: Int32,
        stdout: String,
        stderr: String
    ) -> ZellijDiscoveryResult {
        if status == 127 {
            return .unavailable
        }
        if status != 0 {
            let errorLines = stderr.split(
                separator: "\n",
                omittingEmptySubsequences: false
            )
            let payload = errorLines.lastIndex(where: { $0 == errorMarker })
                .map { errorLines[($0 + 1)...].joined(separator: "\n") }
                ?? stderr
            let detail = payload.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if detail == "No active zellij sessions found." {
                return .available([])
            }
            return .failure(.commandFailed(status: status, stderr: payload))
        }
        let lines = stdout.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard let markerIndex = lines.lastIndex(where: { $0 == marker }) else {
            return .failure(.missingMarker)
        }

        var names = [String]()
        for rawLine in lines[(markerIndex + 1)...] where !rawLine.isEmpty {
            let line = String(rawLine)
            guard let metadata = line.range(
                of: " [Created ",
                options: .backwards
            ) else {
                return .failure(.malformedInventory(line: line))
            }
            let suffix = line[metadata.lowerBound...]
            if suffix.contains("(EXITED - attach to resurrect)") {
                continue
            }
            names.append(String(line[..<metadata.lowerBound]))
        }
        return .available(names)
    }
}
