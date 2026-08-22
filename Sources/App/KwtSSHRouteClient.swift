import Foundation
import GhosthubTransport

struct KwtSSHTarget: Decodable, Equatable, Sendable {
    let hostname: String
    let user: String?
    let port: Int?

    init(hostname: String, user: String? = nil, port: Int? = nil) {
        self.hostname = hostname
        self.user = user
        self.port = port
    }

    init(_ host: SSHHostInfo) {
        self.init(
            hostname: host.hostname,
            user: host.user,
            port: host.port
        )
    }
}

struct KwtSSHExecutionProjection: Decodable, Equatable, Sendable {
    let arguments: [String]
    let privateConfig: [String]

    init(arguments: [String], privateConfig: [String] = []) {
        self.arguments = arguments
        self.privateConfig = privateConfig
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        arguments = try container.decode([String].self, forKey: .arguments)
        privateConfig = try container.decodeIfPresent(
            [String].self,
            forKey: .privateConfig
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case arguments
        case privateConfig = "private_config"
    }
}

struct KwtSSHResolvedTarget: Decodable, Equatable, Sendable {
    let logicalTarget: KwtSSHTarget
    let effectiveTarget: KwtSSHTarget
    let displayTarget: String
    let hostKeyAlias: String?
    let strictHostKeyChecking: String?
    let projection: KwtSSHExecutionProjection

    private enum CodingKeys: String, CodingKey {
        case logicalTarget = "logical_target"
        case effectiveTarget = "effective_target"
        case displayTarget = "display_target"
        case hostKeyAlias = "host_key_alias"
        case strictHostKeyChecking = "strict_host_key_checking"
        case projection
    }
}

struct KwtSSHRouteSnapshot: Decodable, Equatable, Sendable {
    let logicalTarget: KwtSSHTarget
    let targets: [KwtSSHResolvedTarget]
    let routeIdentity: String
    let projectionPolicy: String
    let observedAt: String

    private enum CodingKeys: String, CodingKey {
        case logicalTarget = "logical_target"
        case targets
        case routeIdentity = "route_identity"
        case projectionPolicy = "projection_policy"
        case observedAt = "observed_at"
    }
}

enum KwtSSHRouteError: Error, Equatable, LocalizedError {
    case helperUnavailable
    case commandFailed(status: Int32)
    case malformedOutput
    case unsupportedProjection(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "Ghosthub's bundled kwt helper is unavailable."
        case let .commandFailed(status):
            "kwt SSH resolution failed with status \(status)."
        case .malformedOutput:
            "kwt returned an invalid SSH route snapshot."
        case let .unsupportedProjection(policy):
            "kwt returned an unsupported SSH projection policy: \(policy)."
        }
    }
}

struct KwtSSHRouteClient: Sendable {
    typealias Runner = @Sendable (
        _ executable: String,
        _ arguments: [String],
        _ timeout: TimeInterval
    ) -> AccountCommandOutput

    static let supportedProjectionPolicy = "kwt.openssh.projection.v1"

    private let runner: Runner
    private let binaryPath: String?
    private let timeout: TimeInterval

    init(
        runner: Runner? = nil,
        binaryPath: String? = KwtBinaryLocator.bundledPath(),
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) {
        let processEnvironment = environment
            ?? KwtSSHRuntimeEnvironment.resolved()
        let environmentOverrides = processEnvironment["KWT_HOME"].map {
            ["KWT_HOME": $0]
        } ?? [:]
        self.runner = runner ?? { executable, arguments, timeout in
            AccountCommandRunner.runProcess(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                environmentOverrides: environmentOverrides
            )
        }
        self.binaryPath = binaryPath
        self.timeout = timeout
    }

    func resolve(_ host: SSHHostInfo) throws -> KwtSSHRouteSnapshot {
        guard binaryPath != "" else {
            throw KwtSSHRouteError.helperUnavailable
        }
        let executable = binaryPath ?? "/usr/bin/env"
        var arguments = binaryPath == nil ? ["kwt"] : []
        arguments.append(contentsOf: ["ssh", "resolve", "--json"])
        if let user = host.user {
            arguments.append(contentsOf: ["--user", user])
        }
        if let port = host.port {
            arguments.append(contentsOf: ["--port", String(port)])
        }
        arguments.append(host.hostname)

        let result = runner(executable, arguments, timeout)
        guard result.status == 0 else {
            throw KwtSSHRouteError.commandFailed(status: result.status)
        }
        let snapshot: KwtSSHRouteSnapshot
        do {
            snapshot = try JSONDecoder().decode(
                KwtSSHRouteSnapshot.self,
                from: Data(result.stdout.utf8)
            )
        } catch {
            throw KwtSSHRouteError.malformedOutput
        }
        guard snapshot.projectionPolicy == Self.supportedProjectionPolicy else {
            throw KwtSSHRouteError.unsupportedProjection(
                snapshot.projectionPolicy
            )
        }
        let requestedTarget = KwtSSHTarget(host)
        guard snapshot.logicalTarget == requestedTarget,
              snapshot.targets.last?.logicalTarget == requestedTarget,
              !snapshot.targets.isEmpty,
              !snapshot.routeIdentity.isEmpty,
              !snapshot.observedAt.isEmpty,
              snapshot.targets.allSatisfy({ target in
                  !target.logicalTarget.hostname.isEmpty
                      && !target.effectiveTarget.hostname.isEmpty
                      && !target.projection.arguments.isEmpty
              })
        else {
            throw KwtSSHRouteError.malformedOutput
        }
        return snapshot
    }
}
