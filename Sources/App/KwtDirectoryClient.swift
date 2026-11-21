import Foundation
import GhosthubSettings
import GhosthubTransport
import GhosthubWorkspace

/// Directory browsing and registration both run on the owning host through kwt.
struct KwtDirectoryClient: Sendable {
    typealias Runner = @Sendable (String) -> AccountCommandOutput
    typealias RemoteRunner = @Sendable (SSHHostInfo, [String], String) -> AccountCommandOutput
    private let runner: Runner
    private let remoteRunner: RemoteRunner
    private let binaryPath: String?
    private let remoteRevision: String?
    private let lease: KwtSSHCommandLease
    private static let marker = "GHOSTHUB_DIRECTORY_JSON\n"
    /// Up to 1,000 entries, each with two 4 KiB POSIX paths, a name, and
    /// worst-case six-byte JSON escaping. The runner allocates only bytes read.
    static let maximumOutputBytes = 64 * 1024 * 1024

    init(
        runner: Runner? = nil,
        remoteRunner: RemoteRunner? = nil,
        commandLease: KwtSSHCommandLease? = nil,
        binaryPath: String? = KwtBinaryLocator.bundledPath(),
        remoteRevision: String? = KwtBinaryLocator.bundledRemoteRevision()
    ) {
        self.runner = runner ?? { command in
            AccountCommandRunner(maximumOutputBytes: Self.maximumOutputBytes)
                .runLocalLoginShell(command: command, timeout: 30)
        }
        self.remoteRunner = remoteRunner ?? { host, arguments, command in
            AccountCommandRunner(maximumOutputBytes: Self.maximumOutputBytes)
                .runRemoteLoginShell(
                    host: host, connectionArguments: arguments, command: command, timeout: 30
                )
        }
        self.binaryPath = binaryPath
        self.remoteRevision = remoteRevision
        lease = commandLease ?? KwtSSHCommandLease()
    }

    func browse(_ path: String, on host: CommandHost) async throws -> DirectoryListing {
        let (output, routeIdentity) = try await run("browse", path: path, on: host)
        guard let marker = output.stdout.range(of: Self.marker, options: .backwards),
              var listing = try? JSONDecoder().decode(
                  DirectoryListing.self,
                  from: Data(output.stdout[marker.upperBound...].utf8)
              ),
              listing.path.utf8.first == 0x2F,
              !listing.path.utf8.contains(0),
              listing.entries.count <= 1000,
              Set(listing.entries.map { Data($0.path.utf8) }).count == listing.entries.count,
              listing.entries.allSatisfy({
                  !$0.name.isEmpty && !$0.name.utf8.contains(0x2F) && $0.name != "." && $0.name != ".."
                      && $0.path.utf8.first == 0x2F
                      && !$0.path.utf8.contains(0)
                      &&
                      ($0.projectPath
                          .map { $0.utf8.first == 0x2F && !$0.utf8.contains(0) } ?? true)
                      && DirectoryPaths.key($0.path)
                      == DirectoryPaths.key(listing.path + "/" + $0.name)
              })
        else {
            throw HostProbeError.message("The folder list is invalid.")
        }
        listing.routeIdentity = routeIdentity
        return listing
    }

    func register(
        _ path: String, on host: CommandHost, expectedRouteIdentity: String? = nil
    ) async throws {
        // kwt's stored workspace paths expand environment variables on load.
        // A literal filesystem selection must never register a different path.
        guard !path.utf8.contains(0x24) else {
            throw HostProbeError
                .message("Folder paths with a dollar sign can’t be registered.")
        }
        _ = try await run("add", path: path, on: host, expectedRouteIdentity: expectedRouteIdentity)
    }

    private func run(
        _ operation: String, path: String, on host: CommandHost,
        expectedRouteIdentity: String? = nil
    ) async throws -> (AccountCommandOutput, String?) {
        guard path.utf8.first == 0x2F, !path.utf8.contains(0) else {
            throw HostProbeError.message("Enter an absolute folder path beginning with /.")
        }
        let prelude: String
        switch host {
        case .local:
            prelude = KwtBinaryLocator.commandPrelude(exactPath: binaryPath)
        case let .ssh(info):
            guard info.platform != .windows else {
                throw HostProbeError.message("Directory browsing requires a macOS or Linux host.")
            }
            prelude = KwtBinaryLocator.remoteCommandPrelude(revision: remoteRevision)
        }
        let command = prelude + "printf 'GHOSTHUB_DIRECTORY_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" workspace \(operation) "
            + shellQuotedCommandArgument(path)
        let (output, routeIdentity) = try await lease.withConnection(on: host) { connection in
            if let expectedRouteIdentity, connection?.routeIdentity != expectedRouteIdentity {
                throw HostProbeError
                    .message("The host connection changed. Refresh the parent folder.")
            }
            let output: AccountCommandOutput
            switch host {
            case .local:
                output = await BlockingTask.run { runner(command) }
            case let .ssh(info):
                output = await lease.runCommand(using: connection) { arguments in
                    remoteRunner(info, arguments, command)
                }
            }
            return (output, connection?.routeIdentity)
        }
        try Task.checkCancellation()
        guard output.status == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostProbeError.message(
                detail
                    .isEmpty ? "Could not \(operation) the folder." :
                    detail
            )
        }
        return (output, routeIdentity)
    }
}
