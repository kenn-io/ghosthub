import Foundation
import GhosthubTransport
import GhosthubWorkspace

public enum HerdrDiscoveryResult: Equatable, Sendable {
    case available([HerdrSessionSummary])
    case unavailable
    case failure(HerdrCommandError)
}

public struct HerdrSessionRecord: Equatable, Sendable {
    public let name: String
    public let isDefault: Bool
    public let state: HerdrSessionState
    public let sessionDirectory: String
    public let socketPath: String

    public init(
        name: String,
        isDefault: Bool,
        state: HerdrSessionState,
        sessionDirectory: String,
        socketPath: String
    ) {
        self.name = name
        self.isDefault = isDefault
        self.state = state
        self.sessionDirectory = sessionDirectory
        self.socketPath = socketPath
    }

    public var summary: HerdrSessionSummary {
        HerdrSessionSummary(
            name: name,
            isDefault: isDefault,
            state: state
        )
    }
}

public enum HerdrSessionList {
    public static let marker = "GHOSTHUB_HERDR_JSON"

    public static func command(herdrPath: String = "herdr") -> String {
        let invocation = [
            herdrPath, "session", "list", "--json",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        return [
            HerdrEnvironment.unsetCommand,
            "printf '%s\\n' '\(marker)'",
            "exec \(invocation)",
        ].joined(separator: "; ")
    }

    public static func parse(
        status: Int32,
        stdout: String,
        stderr: String
    ) -> HerdrDiscoveryResult {
        if status == 127 {
            return .unavailable
        }
        switch parseRecords(status: status, stdout: stdout, stderr: stderr) {
        case let .success(records):
            return .available(records.map(\.summary))
        case let .failure(error):
            return .failure(error)
        }
    }

    public static func parseRecords(
        status: Int32,
        stdout: String,
        stderr: String
    ) -> Result<[HerdrSessionRecord], HerdrCommandError> {
        guard status == 0 else {
            return .failure(.commandFailed(status: status, stderr: stderr))
        }

        let lines = stdout.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard let markerIndex = lines.lastIndex(where: { $0 == marker }) else {
            return .failure(.missingMarker)
        }
        let payload = lines[(markerIndex + 1)...].joined(separator: "\n")
        guard let data = payload.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                  SessionListEnvelope.self,
                  from: data
              ) else {
            return .failure(.malformedJSON)
        }

        return .success(envelope.sessions.map { session in
            HerdrSessionRecord(
                name: session.name,
                isDefault: session.default,
                state: session.running ? .running : .stopped,
                sessionDirectory: session.sessionDirectory,
                socketPath: session.socketPath
            )
        })
    }

    private struct SessionListEnvelope: Decodable {
        var sessions: [Session]

        struct Session: Decodable {
            var name: String
            var `default`: Bool
            var running: Bool
            var sessionDirectory: String
            var socketPath: String

            enum CodingKeys: String, CodingKey {
                case name
                case `default`
                case running
                case sessionDirectory = "session_dir"
                case socketPath = "socket_path"
            }
        }
    }
}
