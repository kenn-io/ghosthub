import CryptoKit
import Foundation
import GhosthubSettings
import GhosthubTmux

enum KwtRemoteTarget: String, CaseIterable, Sendable {
    case darwinAMD64 = "darwin-amd64"
    case darwinARM64 = "darwin-arm64"
    case linuxAMD64 = "linux-amd64"
    case linuxARM64 = "linux-arm64"

    init?(operatingSystem: String, architecture: String) {
        let operatingSystem = operatingSystem.lowercased()
        let architecture = architecture.lowercased()
        switch (operatingSystem, architecture) {
        case ("darwin", "x86_64"), ("darwin", "amd64"):
            self = .darwinAMD64
        case ("darwin", "arm64"), ("darwin", "aarch64"):
            self = .darwinARM64
        case ("linux", "x86_64"), ("linux", "amd64"):
            self = .linuxAMD64
        case ("linux", "arm64"), ("linux", "aarch64"):
            self = .linuxARM64
        default:
            return nil
        }
    }

    var checksumCommand: String {
        switch self {
        case .darwinAMD64, .darwinARM64:
            "/usr/bin/shasum -a 256"
        case .linuxAMD64, .linuxARM64:
            "sha256sum"
        }
    }
}

enum KwtRemoteInstallError: Error, Equatable, LocalizedError {
    case invalidHost
    case bundleIncomplete
    case targetProbeFailed(status: Int32)
    case unsupportedTarget(os: String, architecture: String)
    case prepareFailed(status: Int32)
    case uploadFailed(status: Int32, message: String?)
    case installFailed(status: Int32)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Enter a valid SSH destination."
        case .bundleIncomplete:
            "This Ghosthub build does not contain the pinned remote kwt helper."
        case let .targetProbeFailed(status):
            "Ghosthub could not identify the remote platform (status \(status))."
        case let .unsupportedTarget(os, architecture):
            "Ghosthub does not include kwt for \(os)/\(architecture)."
        case let .prepareFailed(status):
            "Ghosthub could not prepare its remote helper directory (status \(status))."
        case let .uploadFailed(status, message):
            if let message {
                "Ghosthub could not copy kwt to the remote host "
                    + "(status \(status)).\n\(message)"
            } else {
                "Ghosthub could not copy kwt to the remote host "
                    + "(status \(status))."
            }
        case let .installFailed(status):
            "The remote kwt integrity or installation check failed (status \(status))."
        case .malformedResponse:
            "The remote host returned an invalid kwt installation response."
        }
    }
}

struct KwtRemoteInstaller: Sendable {
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo, _ command: String
    ) -> (status: Int32, stdout: String)
    typealias UploadRunner = @Sendable (
        _ host: SSHHostInfo, _ source: URL, _ destination: String
    ) -> (status: Int32, output: String)
    typealias ResourceProvider = @Sendable (KwtRemoteTarget) -> URL?

    private static let targetMarker = "GHOSTHUB_KWT_TARGET\t"
    private static let uploadMarker = "GHOSTHUB_KWT_UPLOAD\t"
    private static let installedMarker = "GHOSTHUB_KWT_INSTALLED"

    private let revision: String?
    private let remoteRunner: RemoteRunner
    private let uploadRunner: UploadRunner
    private let resourceProvider: ResourceProvider

    init(
        bundle: Bundle = .main,
        revision: String? = nil,
        remoteRunner: RemoteRunner? = nil,
        uploadRunner: UploadRunner? = nil,
        resourceProvider: ResourceProvider? = nil
    ) {
        self.revision = revision
            ?? KwtBinaryLocator.bundledRemoteRevision(bundle: bundle)
        self.remoteRunner = remoteRunner ?? { host, command in
            TmuxBinaryResolver.runRemoteLoginShell(
                host: host,
                command: command,
                timeout: 30
            )
        }
        self.uploadRunner = uploadRunner ?? Self.upload
        self.resourceProvider = resourceProvider ?? { target in
            let candidate = bundle.bundleURL
                .appendingPathComponent("Contents/Resources/KwtRemote")
                .appendingPathComponent(target.rawValue)
                .appendingPathComponent("kwt")
            return FileManager.default.fileExists(atPath: candidate.path)
                ? candidate
                : nil
        }
    }

    func install(on host: SSHHost) async throws {
        guard let info = TmuxHostResolver.parseSSHDestination(
            host.sshDestination
        ) else {
            throw KwtRemoteInstallError.invalidHost
        }
        let revision = revision
        let remoteRunner = remoteRunner
        let uploadRunner = uploadRunner
        let resourceProvider = resourceProvider
        try await Task.detached(priority: .userInitiated) {
            guard let revision,
                  KwtBinaryLocator.remoteManagedPath(
                      revision: revision
                  ) != nil
            else {
                throw KwtRemoteInstallError.bundleIncomplete
            }

            let probe = remoteRunner(info, Self.targetProbeCommand)
            guard probe.status == 0 else {
                throw KwtRemoteInstallError.targetProbeFailed(
                    status: probe.status
                )
            }
            let (operatingSystem, architecture) = try Self.parseTarget(
                probe.stdout
            )
            guard let target = KwtRemoteTarget(
                operatingSystem: operatingSystem,
                architecture: architecture
            ) else {
                throw KwtRemoteInstallError.unsupportedTarget(
                    os: operatingSystem,
                    architecture: architecture
                )
            }
            guard let helperURL = resourceProvider(target),
                  let helperData = try? Data(contentsOf: helperURL)
            else {
                throw KwtRemoteInstallError.bundleIncomplete
            }
            let digest = SHA256.hash(data: helperData)
                .map { String(format: "%02x", $0) }
                .joined()
            let incomingName = ".incoming-\(UUID().uuidString.lowercased())"
            let prepare = remoteRunner(
                info,
                Self.prepareCommand(
                    revision: revision,
                    incomingName: incomingName
                )
            )
            guard prepare.status == 0 else {
                throw KwtRemoteInstallError.prepareFailed(
                    status: prepare.status
                )
            }
            do {
                let uploadPath = try Self.parseUploadPath(prepare.stdout)
                let upload = uploadRunner(info, helperURL, uploadPath)
                guard upload.status == 0 else {
                    let message = upload.output.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    throw KwtRemoteInstallError.uploadFailed(
                        status: upload.status,
                        message: message.isEmpty ? nil : message
                    )
                }
                let install = remoteRunner(
                    info,
                    Self.installCommand(
                        target: target,
                        revision: revision,
                        incomingName: incomingName,
                        digest: digest
                    )
                )
                guard install.status == 0 else {
                    throw KwtRemoteInstallError.installFailed(
                        status: install.status
                    )
                }
                guard install.stdout.split(whereSeparator: \.isNewline)
                    .contains(Substring(Self.installedMarker))
                else {
                    throw KwtRemoteInstallError.malformedResponse
                }
            } catch {
                _ = remoteRunner(
                    info,
                    Self.cleanupCommand(
                        revision: revision,
                        incomingName: incomingName
                    )
                )
                throw error
            }
        }.value
    }

    static let targetProbeCommand =
        "ghosthub_kwt_os=$(uname -s) || exit $?; "
            + "ghosthub_kwt_arch=$(uname -m) || exit $?; "
            + "printf 'GHOSTHUB_KWT_TARGET\\t%s\\t%s\\n' "
            + "\"$ghosthub_kwt_os\" \"$ghosthub_kwt_arch\""

    static func prepareCommand(
        revision: String,
        incomingName: String
    ) -> String {
        let directory = "$HOME/.ghosthub/helpers/kwt/\(revision)"
        return "umask 077; "
            + "ghosthub_kwt_dir=\"\(directory)\"; "
            + "mkdir -p \"$ghosthub_kwt_dir\" || exit $?; "
            + "printf 'GHOSTHUB_KWT_UPLOAD\\t%s/%s\\n' "
            + "\"$ghosthub_kwt_dir\" "
            + shellQuotedCommandArgument(incomingName)
    }

    static func installCommand(
        target: KwtRemoteTarget,
        revision: String,
        incomingName: String,
        digest: String
    ) -> String {
        let directory = "$HOME/.ghosthub/helpers/kwt/\(revision)"
        return "ghosthub_kwt_dir=\"\(directory)\"; "
            + "ghosthub_kwt_incoming=\"$ghosthub_kwt_dir/"
            + "\(incomingName)\"; "
            + "ghosthub_kwt_target=\"$ghosthub_kwt_dir/kwt\"; "
            + "trap 'rm -f \"$ghosthub_kwt_incoming\"' EXIT; "
            + "ghosthub_kwt_digest=$(\(target.checksumCommand) "
            + "\"$ghosthub_kwt_incoming\" | awk '{print $1}') || exit $?; "
            + "[ \"$ghosthub_kwt_digest\" = "
            + shellQuotedCommandArgument(digest)
            + " ] || exit 65; "
            + "chmod 0755 \"$ghosthub_kwt_incoming\" || exit $?; "
            + "ghosthub_kwt_version=$(\"$ghosthub_kwt_incoming\" version) "
            + "|| exit $?; "
            + "ghosthub_kwt_version_first=$(printf '%s\\n' "
            + "\"$ghosthub_kwt_version\" | sed -n '1p') || exit $?; "
            + "[ \"$ghosthub_kwt_version_first\" = "
            + shellQuotedCommandArgument("kwt version \(revision)")
            + " ] || exit 66; "
            + "if [ -f \"$ghosthub_kwt_target\" ]; then "
            + "cp -p \"$ghosthub_kwt_target\" "
            + "\"$ghosthub_kwt_target.previous\" || exit $?; fi; "
            + "mv -f \"$ghosthub_kwt_incoming\" "
            + "\"$ghosthub_kwt_target\" || exit $?; "
            + "trap - EXIT; printf 'GHOSTHUB_KWT_INSTALLED\\n'"
    }

    static func cleanupCommand(
        revision: String,
        incomingName: String
    ) -> String {
        let directory = "$HOME/.ghosthub/helpers/kwt/\(revision)"
        return "ghosthub_kwt_dir=\"\(directory)\"; "
            + "rm -f \"$ghosthub_kwt_dir/"
            + "\(incomingName)\""
    }

    private static func parseTarget(
        _ output: String
    ) throws -> (String, String) {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard line.hasPrefix(Substring(targetMarker)) else {
                continue
            }
            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            )
            guard fields.count == 3 else { break }
            return (String(fields[1]), String(fields[2]))
        }
        throw KwtRemoteInstallError.malformedResponse
    }

    private static func parseUploadPath(_ output: String) throws -> String {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard line.hasPrefix(Substring(uploadMarker)) else {
                continue
            }
            let path = line.dropFirst(uploadMarker.count)
            guard path.hasPrefix("/"), !path.contains("\t") else {
                break
            }
            return String(path)
        }
        throw KwtRemoteInstallError.malformedResponse
    }

    private static func upload(
        host: SSHHostInfo,
        source: URL,
        destination: String
    ) -> (status: Int32, output: String) {
        let result = TmuxBinaryResolver.runProcessInLoginShell(
            executable: "/usr/bin/scp",
            arguments: uploadArguments(
                host: host,
                source: source,
                destination: destination
            ),
            timeout: 120,
            captureStandardError: true
        )
        return (result.status, result.stdout)
    }

    static func uploadArguments(
        host: SSHHostInfo,
        source: URL,
        destination: String
    ) -> [String] {
        var arguments = [
            "-q", "-B",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
        ]
        arguments.append(contentsOf: tmuxSSHConnectionArguments())
        arguments.append(contentsOf:
            SSHConfigurationResolver.noninteractiveHostKeyArguments(
                for: host
            ))
        if let port = host.port, port != 22 {
            arguments.append(contentsOf: ["-P", String(port)])
        }
        let hostname =
            host.hostname.contains(":")
                && !(host.hostname.hasPrefix("[")
                    && host.hostname.hasSuffix("]"))
                ? "[\(host.hostname)]"
                : host.hostname
        let target = host.user.map { "\($0)@\(hostname)" }
            ?? hostname
        arguments.append(source.path)
        arguments.append("\(target):\(destination)")
        return arguments
    }
}
