import Foundation
import GhosthubSettings
import GhosthubTransport
import GhosthubWorkspace

/// Directory browsing and registration both run on the owning host through kwt.
struct KwtDirectoryClient: Sendable {
    typealias Runner = @Sendable (String) -> AccountCommandOutput
    private let runner: Runner
    private let binaryPath: String?
    private let remoteRevision: String?
    private let lease: KwtSSHCommandLease
    private static let marker = "GHOSTHUB_DIRECTORY_JSON\n"

    init(
        runner: Runner? = nil,
        binaryPath: String? = KwtBinaryLocator.bundledPath(),
        remoteRevision: String? = KwtBinaryLocator.bundledRemoteRevision()
    ) {
        self.runner = runner ?? { command in
            AccountCommandRunner().runLocalLoginShell(command: command, timeout: 30)
        }
        self.binaryPath = binaryPath
        self.remoteRevision = remoteRevision
        lease = KwtSSHCommandLease()
    }

    func browse(_ path: String, on host: CommandHost) async throws -> DirectoryListing {
        let output = try await run("browse", path: path, on: host)
        guard let marker = output.stdout.range(of: Self.marker, options: .backwards),
              let listing = try? JSONDecoder().decode(
                  DirectoryListing.self,
                  from: Data(output.stdout[marker.upperBound...].utf8)
              ),
              listing.path.hasPrefix("/"),
              listing.entries.count <= 1000,
              Set(listing.entries.map(\.path)).count == listing.entries.count,
              listing.entries.allSatisfy({
                  !$0.name.isEmpty && !$0.name.contains("/") && $0.name != "." && $0.name != ".."
                      && $0.path.hasPrefix("/")
                      && !$0.path.contains("\0")
                      && ($0.projectPath.map { $0.hasPrefix("/") && !$0.contains("\0") } ?? true)
                      && DirectoryPaths.normalized($0.path)
                      == DirectoryPaths.normalized(listing.path + "/" + $0.name)
              })
        else {
            throw HostProbeError.message("kwt returned an invalid folder listing.")
        }
        return listing
    }

    func register(_ path: String, on host: CommandHost) async throws {
        // kwt's stored workspace paths expand environment variables on load.
        // A literal filesystem selection must never register a different path.
        guard !path.contains("$") else {
            throw HostProbeError
                .message("kwt cannot register directory paths containing a dollar sign.")
        }
        _ = try await run("add", path: path, on: host)
    }

    private func run(
        _ operation: String, path: String, on host: CommandHost
    ) async throws -> AccountCommandOutput {
        guard path.hasPrefix("/"), !path.contains("\0") else {
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
        let output: AccountCommandOutput
        switch host {
        case .local:
            let runner = runner
            output = await BlockingTask.run { runner(command) }
        case let .ssh(info):
            output = try await lease.withConnection(on: host) { connection in
                await lease.runCommand(using: connection) { arguments in
                    AccountCommandRunner().runRemoteLoginShell(
                        host: info, connectionArguments: arguments,
                        command: command, timeout: 30
                    )
                }
            }
        }
        try Task.checkCancellation()
        guard output.status == 0 else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HostProbeError.message(
                detail
                    .isEmpty ? "Could not \(operation) the directory (status \(output.status))." :
                    detail
            )
        }
        return output
    }
}
