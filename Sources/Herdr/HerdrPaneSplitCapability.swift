import Foundation
import GhosthubTransport
import GhosthubWorkspace

public struct HerdrVersion: Comparable, Equatable, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public static let paneSplitting = HerdrVersion(
        major: 0,
        minor: 8,
        patch: 0
    )

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(output: String) {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, fields[0] == "herdr" else { return nil }
        let components = fields[1].split(separator: ".")
        guard components.count >= 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(
                  components[2].prefix(while: \.isNumber)
              )
        else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}

public struct HerdrPaneSplitCapability: Equatable, Sendable {
    public var version: HerdrVersion
    public var session: HerdrSessionRecord

    public init(version: HerdrVersion, session: HerdrSessionRecord) {
        self.version = version
        self.session = session
    }
}

public enum HerdrPaneSplitCapabilityProbe {
    public static let versionMarker = "GHOSTHUB_HERDR_VERSION"

    public static func command(herdrPath: String) -> String {
        let executable = shellQuotedCommandArgument(herdrPath)
        let version = executable + " '--version'"
        let inventory = [
            herdrPath, "session", "list", "--json",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        return [
            HerdrEnvironment.unsetCommand,
            "ghosthub_herdr_version=$(\(version)) || exit $?",
            "printf '%s\\n%s\\n' '\(versionMarker)' "
                + "\"$ghosthub_herdr_version\"",
            "printf '%s\\n' '\(HerdrSessionList.marker)'",
            "exec \(inventory)",
        ].joined(separator: "; ")
    }

    public static func parse(
        status: Int32,
        stdout: String,
        stderr: String,
        sessionName: String
    ) -> Result<HerdrPaneSplitCapability?, HerdrCommandError> {
        guard status == 0 else {
            return .failure(.commandFailed(status: status, stderr: stderr))
        }
        let lines = stdout.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let markerIndex = lines.lastIndex(of: versionMarker),
              lines.indices.contains(markerIndex + 1)
        else {
            return .failure(.missingMarker)
        }
        guard let version = HerdrVersion(output: lines[markerIndex + 1]) else {
            return .failure(.malformedVersion)
        }
        let records: [HerdrSessionRecord]
        switch HerdrSessionList.parseRecords(
            status: status,
            stdout: stdout,
            stderr: stderr
        ) {
        case let .success(value):
            records = value
        case let .failure(error):
            return .failure(error)
        }
        guard version >= .paneSplitting,
              let session = records.first(where: {
                  $0.name == sessionName && $0.state == .running
              })
        else {
            return .success(nil)
        }
        return .success(HerdrPaneSplitCapability(
            version: version,
            session: session
        ))
    }
}
