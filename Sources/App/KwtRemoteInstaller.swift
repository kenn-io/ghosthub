import GhosthubTransport
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
        _ host: SSHHostInfo, _ connectionArguments: [String], _ command: String
    ) -> AccountCommandOutput
    typealias UploadRunner = @Sendable (
        _ host: SSHHostInfo, _ source: URL, _ destination: String,
        _ connectionArguments: [String]
    ) -> AccountCommandOutput
    typealias ResourceProvider = @Sendable (KwtRemoteTarget) -> URL?

    private static let targetMarker = "GHOSTHUB_KWT_TARGET\t"
    private static let uploadMarker = "GHOSTHUB_KWT_UPLOAD\t"
    private static let readyMarker = "GHOSTHUB_KWT_READY"
    private static let installedMarker = "GHOSTHUB_KWT_INSTALLED"

    private let revision: String?
    private let remoteRunner: RemoteRunner
    private let uploadRunner: UploadRunner
    private let resourceProvider: ResourceProvider
    private let commandLease: KwtSSHCommandLease

    init(
        bundle: Bundle = .main,
        revision: String? = nil,
        remoteRunner: RemoteRunner? = nil,
        uploadRunner: UploadRunner? = nil,
        resourceProvider: ResourceProvider? = nil,
        commandLease: KwtSSHCommandLease? = nil
    ) {
        self.revision = revision
            ?? KwtBinaryLocator.bundledRemoteRevision(bundle: bundle)
        self.remoteRunner = remoteRunner ?? { host, arguments, command in
            AccountCommandRunner().runRemoteLoginShell(
                host: host,
                connectionArguments: arguments,
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
        self.commandLease = commandLease ?? .unlessInjected(
            remoteRunner != nil || uploadRunner != nil
        )
    }

    func install(on host: SSHHost) async throws {
        try await install(on: host, ifNeeded: false)
    }

    func ensureInstalled(on host: SSHHost) async throws {
        try await install(on: host, ifNeeded: true)
    }

    private func install(
        on host: SSHHost,
        ifNeeded: Bool
    ) async throws {
        guard let info = CommandHostResolver.parseSSHDestination(
            host.sshDestination
        ) else {
            throw KwtRemoteInstallError.invalidHost
        }
        let commandLease = commandLease
        try await commandLease.withConnection(on: .ssh(info)) { connection in
            guard let connection else {
                throw KwtRemoteInstallError.invalidHost
            }
            try await install(
                on: info,
                connection: connection,
                ifNeeded: ifNeeded
            )
        }
    }

    private func install(
        on info: SSHHostInfo,
        connection: KwtSSHConnection,
        ifNeeded: Bool
    ) async throws {
        let revision = revision
        let remoteRunner = remoteRunner
        let uploadRunner = uploadRunner
        let resourceProvider = resourceProvider
        let commandLease = commandLease
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let revision,
                  KwtBinaryLocator.remoteManagedPath(
                      revision: revision
                  ) != nil
            else {
                throw KwtRemoteInstallError.bundleIncomplete
            }

            if ifNeeded {
                let ready = await commandLease.runCommand(
                    using: connection
                ) { arguments in
                    remoteRunner(
                        info,
                        arguments,
                        Self.readyProbeCommand(revision: revision)
                    )
                }
                try Task.checkCancellation()
                if ready.status == 0,
                   ready.stdout.split(whereSeparator: \.isNewline)
                   .contains(Substring(Self.readyMarker)) {
                    return
                }
            }

            let probe = await commandLease.runCommand(using: connection) {
                arguments in
                remoteRunner(info, arguments, Self.targetProbeCommand)
            }
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            let prepare = await commandLease.runCommand(using: connection) {
                arguments in
                remoteRunner(
                    info,
                    arguments,
                    Self.prepareCommand(
                        revision: revision,
                        incomingName: incomingName
                    )
                )
            }
            try Task.checkCancellation()
            guard prepare.status == 0 else {
                throw KwtRemoteInstallError.prepareFailed(
                    status: prepare.status
                )
            }
            do {
                let uploadPath = try Self.parseUploadPath(prepare.stdout)
                try Task.checkCancellation()
                let upload = await commandLease.runCommand(
                    using: connection
                ) { arguments in
                    uploadRunner(info, helperURL, uploadPath, arguments)
                }
                guard upload.status == 0 else {
                    let diagnostic = upload.stderr.isEmpty
                        ? upload.stdout
                        : upload.stderr
                    let message = diagnostic.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    throw KwtRemoteInstallError.uploadFailed(
                        status: upload.status,
                        message: message.isEmpty ? nil : message
                    )
                }
                try Task.checkCancellation()
                let install = await commandLease.runCommand(
                    using: connection
                ) { arguments in
                    remoteRunner(
                        info,
                        arguments,
                        Self.installCommand(
                            target: target,
                            revision: revision,
                            incomingName: incomingName,
                            digest: digest
                        )
                    )
                }
                try Task.checkCancellation()
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
                _ = await commandLease.runCommand(using: connection) {
                    arguments in
                    remoteRunner(
                        info,
                        arguments,
                        Self.cleanupCommand(
                            revision: revision,
                            incomingName: incomingName
                        )
                    )
                }
                throw error
            }
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    static let targetProbeCommand =
        "ghosthub_kwt_os=$(uname -s) || exit $?; "
            + "ghosthub_kwt_arch=$(uname -m) || exit $?; "
            + "printf 'GHOSTHUB_KWT_TARGET\\t%s\\t%s\\n' "
            + "\"$ghosthub_kwt_os\" \"$ghosthub_kwt_arch\""

    static func readyProbeCommand(revision: String) -> String {
        let path = "$HOME/.ghosthub/helpers/kwt/\(revision)/kwt"
        return "ghosthub_kwt_path=\"\(path)\"; "
            + "[ -x \"$ghosthub_kwt_path\" ] || exit 1; "
            + "ghosthub_kwt_version=$(\"$ghosthub_kwt_path\" version) "
            + "|| exit $?; "
            + "ghosthub_kwt_version_first=$(printf '%s\\n' "
            + "\"$ghosthub_kwt_version\" | sed -n '1p') || exit $?; "
            + "[ \"$ghosthub_kwt_version_first\" = "
            + shellQuotedCommandArgument("kwt version \(revision)")
            + " ] || exit 1; printf 'GHOSTHUB_KWT_READY\\n'"
    }

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
        destination: String,
        connectionArguments: [String]
    ) -> AccountCommandOutput {
        let command = (["/usr/bin/scp"] + uploadArguments(
            host: host,
            source: source,
            destination: destination,
            connectionArguments: connectionArguments
        ))
        .map(shellQuotedCommandArgument)
        .joined(separator: " ")
        return AccountCommandRunner().runLocalLoginShell(
            command: command,
            timeout: 120
        )
    }

    static func uploadArguments(
        host: SSHHostInfo,
        source: URL,
        destination: String,
        connectionArguments: [String]
    ) -> [String] {
        var arguments = [
            "-q", "-B",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
        ]
        arguments.append(contentsOf: KwtSSHCommandLease.scpArguments(
            from: connectionArguments
        ))
        if let port = host.port {
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

actor KwtRemoteProvisioningCoordinator {
    static let shared = KwtRemoteProvisioningCoordinator()

    private enum Intent: Equatable {
        case ensureInstalled
        case install
    }

    private struct HostKey: Hashable {
        let configKey: String
        let platform: String
        let sshDestination: String
    }

    private struct InFlight {
        let intent: Intent
        let task: Task<Void, Error>
        var waiters: [UUID: Intent]
    }

    private var inFlight: [HostKey: InFlight] = [:]
    private let installer: KwtRemoteInstaller

    init(installer: KwtRemoteInstaller = KwtRemoteInstaller()) {
        self.installer = installer
    }

    func ensureInstalled(on host: SSHHost) async throws {
        try await provision(on: host, intent: .ensureInstalled)
    }

    func install(on host: SSHHost) async throws {
        try await provision(on: host, intent: .install)
    }

    private func provision(
        on host: SSHHost,
        intent requestedIntent: Intent
    ) async throws {
        let key = HostKey(
            configKey: host.configKey,
            platform: host.platform.rawValue,
            sshDestination: host.sshDestination
        )
        let waiterID = UUID()
        while true {
            let task: Task<Void, Error>
            let runningIntent: Intent
            if var existing = inFlight[key] {
                if existing.waiters[waiterID] == nil {
                    existing.waiters[waiterID] = requestedIntent
                    inFlight[key] = existing
                }
                task = existing.task
                runningIntent = existing.intent
            } else {
                task = provisioningTask(on: host, intent: requestedIntent)
                inFlight[key] = InFlight(
                    intent: requestedIntent,
                    task: task,
                    waiters: [waiterID: requestedIntent]
                )
                runningIntent = requestedIntent
            }

            do {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await task.value
                    try Task.checkCancellation()
                } onCancel: {
                    Task {
                        await self.releaseWaiter(waiterID, for: key)
                    }
                }
            } catch {
                guard requestedIntent == .install,
                      runningIntent == .ensureInstalled,
                      !Task.isCancelled
                else {
                    releaseWaiter(waiterID, for: key)
                    throw error
                }
                promoteEnsureToInstall(on: host, for: key)
                continue
            }

            guard requestedIntent == .install,
                  runningIntent == .ensureInstalled
            else {
                releaseWaiter(waiterID, for: key)
                return
            }
            promoteEnsureToInstall(on: host, for: key)
        }
    }

    private func provisioningTask(
        on host: SSHHost,
        intent: Intent
    ) -> Task<Void, Error> {
        let installer = installer
        return Task {
            switch intent {
            case .ensureInstalled:
                try await installer.ensureInstalled(on: host)
            case .install:
                try await installer.install(on: host)
            }
        }
    }

    private func promoteEnsureToInstall(
        on host: SSHHost,
        for key: HostKey
    ) {
        guard let existing = inFlight[key],
              existing.intent == .ensureInstalled
        else { return }
        let forcedWaiters = existing.waiters.filter {
            $0.value == .install
        }
        guard !forcedWaiters.isEmpty else { return }
        inFlight[key] = InFlight(
            intent: .install,
            task: provisioningTask(on: host, intent: .install),
            waiters: forcedWaiters
        )
    }

    private func releaseWaiter(_ waiterID: UUID, for key: HostKey) {
        guard var existing = inFlight[key],
              existing.waiters.removeValue(forKey: waiterID) != nil
        else { return }
        guard !existing.waiters.isEmpty else {
            inFlight.removeValue(forKey: key)
            existing.task.cancel()
            return
        }
        inFlight[key] = existing
    }
}
