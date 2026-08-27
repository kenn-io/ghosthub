import GhosthubTransport
import CryptoKit
import Foundation
import GhosthubSettings
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("Managed remote kwt installation")
struct KwtRemoteInstallerTests {
    @Test("missing Linux arm64 helper is installed by exact revision")
    func installsLinuxARM64Helper() async throws {
        let revision = String(repeating: "d", count: 40)
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("pinned kwt".utf8).write(to: helperURL)
        defer { try? FileManager.default.removeItem(at: helperURL) }
        let recorder = KwtInstallRecorder()
        let installer = KwtRemoteInstaller(
            revision: revision,
            remoteRunner: { _, _, command in
                recorder.record(command: command)
                if command == KwtRemoteInstaller.readyProbeCommand(
                    revision: revision
                ) {
                    return installOutput(1)
                }
                if command == KwtRemoteInstaller.targetProbeCommand {
                    return installOutput(
                        0,
                        "banner\nGHOSTHUB_KWT_TARGET\tLinux\taarch64\n"
                    )
                }
                if command.contains("GHOSTHUB_KWT_UPLOAD") {
                    return installOutput(
                        0,
                        "GHOSTHUB_KWT_UPLOAD\t/home/user-a/.ghosthub/"
                            + "helpers/kwt/\(revision)/.incoming-test\n"
                    )
                }
                return installOutput(0, "GHOSTHUB_KWT_INSTALLED\n")
            },
            uploadRunner: { host, source, destination, _ in
                recorder.record(
                    host: host,
                    source: source,
                    destination: destination
                )
                return installOutput(0)
            },
            resourceProvider: { target in
                #expect(target == .linuxARM64)
                return helperURL
            }
        )

        try await installer.ensureInstalled(on: SSHHost(
            configKey: "linux-build",
            name: "Linux Build Host",
            platform: .linux,
            sshDestination: "operator@build.example.test:2222"
        ))

        #expect(recorder.host == SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: 2222
        ))
        #expect(recorder.source == helperURL)
        #expect(recorder.destination?.contains(revision) == true)
        let installCommand = try #require(recorder.commands.last)
        #expect(installCommand.contains("sha256sum"))
        #expect(installCommand.contains(
            "\"$ghosthub_kwt_target.previous\""
        ))
        #expect(installCommand.contains("mv -f"))
        #expect(installCommand.contains(revision))
        #expect(installCommand.contains("kwt version \(revision)"))
    }

    @Test("exact installed helper skips upload")
    func exactInstalledHelperSkipsUpload() async throws {
        let revision = String(repeating: "c", count: 40)
        let recorder = KwtInstallRecorder()
        let installer = KwtRemoteInstaller(
            revision: revision,
            remoteRunner: { _, _, command in
                recorder.record(command: command)
                return installOutput(0, "banner\nGHOSTHUB_KWT_READY\n")
            },
            uploadRunner: { host, source, destination, _ in
                recorder.record(
                    host: host,
                    source: source,
                    destination: destination
                )
                return installOutput(0)
            },
            resourceProvider: { _ in nil }
        )

        try await installer.ensureInstalled(on: SSHHost(
            configKey: "mac-build",
            name: "macOS Build Host",
            platform: .macOS,
            sshDestination: "operator@mac-build.example.test"
        ))

        #expect(recorder.commands == [
            KwtRemoteInstaller.readyProbeCommand(revision: revision),
        ])
        #expect(recorder.destination == nil)
    }

    @Test("cancelling the last provisioning waiter stops before upload")
    func cancellationStopsProvisioningBeforeUpload() async throws {
        let revision = String(repeating: "b", count: 40)
        let probeStarted = AsyncStream<Void>.makeStream()
        let probeCancelled = AsyncStream<Void>.makeStream()
        let recorder = KwtInstallRecorder()
        let installer = KwtRemoteInstaller(
            revision: revision,
            remoteRunner: { _, _, command in
                recorder.record(command: command)
                if command == KwtRemoteInstaller.readyProbeCommand(
                    revision: revision
                ) {
                    return installOutput(1)
                }
                if command == KwtRemoteInstaller.targetProbeCommand {
                    probeStarted.continuation.yield()
                    while !Task.isCancelled {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    probeCancelled.continuation.yield()
                    probeCancelled.continuation.finish()
                    return installOutput(
                        0,
                        "GHOSTHUB_KWT_TARGET\tLinux\taarch64\n"
                    )
                }
                return installOutput(0)
            },
            uploadRunner: { host, source, destination, _ in
                recorder.record(
                    host: host,
                    source: source,
                    destination: destination
                )
                return installOutput(0)
            },
            resourceProvider: { _ in nil }
        )
        let coordinator = KwtRemoteProvisioningCoordinator(
            installer: installer
        )
        let task = Task {
            try await coordinator.ensureInstalled(on: SSHHost(
                configKey: "linux-build",
                name: "Linux Build Host",
                platform: .linux,
                sshDestination: "operator@build.example.test"
            ))
        }

        var probeEvents = probeStarted.stream.makeAsyncIterator()
        _ = await probeEvents.next()
        task.cancel()
        var cancellationEvents = probeCancelled.stream.makeAsyncIterator()
        _ = await cancellationEvents.next()
        await #expect {
            try await task.value
        } throws: {
            $0 is CancellationError
        }
        #expect(recorder.destination == nil)
    }

    @Test("cancellation after upload prevents helper activation")
    func cancellationAfterUploadPreventsActivation() async throws {
        let revision = String(repeating: "9", count: 40)
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("pinned kwt".utf8).write(to: helperURL)
        defer { try? FileManager.default.removeItem(at: helperURL) }
        let uploadStarted = AsyncStream<Void>.makeStream()
        let uploadCancelled = AsyncStream<Void>.makeStream()
        let recorder = KwtInstallRecorder()
        let installer = KwtRemoteInstaller(
            revision: revision,
            remoteRunner: { _, _, command in
                recorder.record(command: command)
                if command == KwtRemoteInstaller.targetProbeCommand {
                    return installOutput(
                        0,
                        "GHOSTHUB_KWT_TARGET\tLinux\taarch64\n"
                    )
                }
                if command.contains("GHOSTHUB_KWT_UPLOAD") {
                    return installOutput(
                        0,
                        "GHOSTHUB_KWT_UPLOAD\t/home/user-a/.ghosthub/"
                            + "helpers/kwt/\(revision)/.incoming-test\n"
                    )
                }
                return installOutput(0, "GHOSTHUB_KWT_INSTALLED\n")
            },
            uploadRunner: { host, source, destination, _ in
                recorder.record(
                    host: host,
                    source: source,
                    destination: destination
                )
                uploadStarted.continuation.yield()
                while !Task.isCancelled {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                uploadCancelled.continuation.yield()
                uploadCancelled.continuation.finish()
                return installOutput(0)
            },
            resourceProvider: { _ in helperURL }
        )
        let task = Task {
            try await installer.install(on: SSHHost(
                configKey: "linux-build",
                name: "Linux Build Host",
                platform: .linux,
                sshDestination: "operator@build.example.test"
            ))
        }

        var uploadEvents = uploadStarted.stream.makeAsyncIterator()
        _ = await uploadEvents.next()
        task.cancel()
        var cancellationEvents = uploadCancelled.stream.makeAsyncIterator()
        _ = await cancellationEvents.next()
        await #expect {
            try await task.value
        } throws: {
            $0 is CancellationError
        }
        #expect(recorder.destination != nil)
        #expect(!recorder.commands.contains {
            $0.contains("GHOSTHUB_KWT_INSTALLED")
        })
        let cleanupCommand = try #require(recorder.commands.last)
        #expect(cleanupCommand.contains("rm -f"))
    }

    @Test("uploaded helper must report the exact pinned revision")
    func rejectsMismatchedUploadedRevision() throws {
        let revision = String(repeating: "a", count: 40)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let helperDirectory = home
            .appendingPathComponent(".ghosthub/helpers/kwt/\(revision)")
        try FileManager.default.createDirectory(
            at: helperDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let incomingName = ".incoming-test"
        let incoming = helperDirectory.appendingPathComponent(incomingName)
        let helper = """
        #!/bin/sh
        printf 'kwt version \(String(repeating: "b", count: 40))\\n'
        """
        try helper.write(to: incoming, atomically: true, encoding: .utf8)
        let digest = SHA256.hash(data: Data(helper.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let command = KwtRemoteInstaller.installCommand(
            target: .darwinARM64,
            revision: revision,
            incomingName: incomingName,
            digest: digest
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 66)
        #expect(!FileManager.default.fileExists(
            atPath: helperDirectory.appendingPathComponent("kwt").path
        ))
    }

    @Test("SFTP upload receives the absolute path without shell quotes")
    func usesPlainSFTPDestination() {
        let arguments = KwtRemoteInstaller.uploadArguments(
            host: SSHHostInfo(
                user: "user-a",
                hostname: "host-a.example",
                port: nil
            ),
            source: URL(fileURLWithPath: "/tmp/pinned kwt"),
            destination:
            "/home/user-a/.ghosthub/helpers/kwt/revision/.incoming-test",
            connectionArguments: []
        )

        #expect(
            arguments.last
                == "user-a@host-a.example:/home/user-a/.ghosthub/helpers/"
                + "kwt/revision/.incoming-test"
        )
    }

    @Test("SCP brackets an IPv6 host while preserving its username")
    func bracketsIPv6Destination() {
        let arguments = KwtRemoteInstaller.uploadArguments(
            host: SSHHostInfo(
                user: "user-a",
                hostname: "2001:db8::42",
                port: nil
            ),
            source: URL(fileURLWithPath: "/tmp/kwt"),
            destination: "/home/user-a/.ghosthub/helpers/kwt",
            connectionArguments: []
        )

        #expect(
            arguments.last
                == "user-a@[2001:db8::42]:/home/user-a/.ghosthub/helpers/kwt"
        )
    }

    @Test("SCP reuses authentication and preserves an explicit port")
    func reusesAuthenticationForUpload() throws {
        let arguments = KwtRemoteInstaller.uploadArguments(
            host: SSHHostInfo(
                user: "developer",
                hostname: "build-node.example.test",
                port: 22
            ),
            source: URL(fileURLWithPath: "/tmp/kwt"),
            destination: "/opt/ghosthub/kwt",
            connectionArguments: ["-o", "ControlPath=/tmp/control"]
        )

        #expect(arguments.contains(where: { $0.hasPrefix("ControlPath=") }))
        #expect(arguments.contains("-B"))
        let portIndex = try #require(arguments.firstIndex(of: "-P"))
        #expect(arguments[portIndex + 1] == "22")
    }

    @Test("SCP translates the kwt SSH projection port option")
    func translatesProjectedPortForUpload() throws {
        let arguments = KwtRemoteInstaller.uploadArguments(
            host: SSHHostInfo(
                user: "developer",
                hostname: "build-node.example.test",
                port: nil
            ),
            source: URL(fileURLWithPath: "/tmp/kwt"),
            destination: "/opt/ghosthub/kwt",
            connectionArguments: ["-F", "/dev/null", "-p", "2200"]
        )

        #expect(!arguments.contains("-p"))
        let portIndex = try #require(arguments.firstIndex(of: "-P"))
        #expect(arguments[portIndex + 1] == "2200")
    }

    @Test("upload failures preserve the SCP diagnostic")
    func preservesUploadFailureDiagnostic() async throws {
        let revision = String(repeating: "e", count: 40)
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("pinned kwt".utf8).write(to: helperURL)
        defer { try? FileManager.default.removeItem(at: helperURL) }
        let recorder = KwtInstallRecorder()
        let installer = KwtRemoteInstaller(
            revision: revision,
            remoteRunner: { _, _, command in
                recorder.record(command: command)
                if command == KwtRemoteInstaller.targetProbeCommand {
                    return installOutput(
                        0,
                        "GHOSTHUB_KWT_TARGET\tLinux\tx86_64\n"
                    )
                }
                return installOutput(
                    0,
                    "GHOSTHUB_KWT_UPLOAD\t/home/user-a/.ghosthub/"
                        + "helpers/kwt/\(revision)/.incoming-test\n"
                )
            },
            uploadRunner: { _, _, _, _ in
                installOutput(
                    1,
                    stderr: "scp: destination is unavailable\n"
                )
            },
            resourceProvider: { _ in helperURL }
        )

        await #expect {
            try await installer.install(on: SSHHost(
                configKey: "linux-build",
                name: "Linux Build Host",
                platform: .linux,
                sshDestination: "operator@build.example.test"
            ))
        } throws: {
            $0 as? KwtRemoteInstallError
                == .uploadFailed(
                    status: 1,
                    message: "scp: destination is unavailable"
                )
        }

        let cleanupCommand = try #require(recorder.commands.last)
        #expect(cleanupCommand.contains("rm -f"))
        #expect(cleanupCommand.contains(revision))
        #expect(cleanupCommand.contains(".incoming-"))
    }

    @Test("install transport failures clean the prepared incoming file")
    func cleansIncomingFileAfterInstallTransportFailure() async throws {
        let revision = String(repeating: "f", count: 40)
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("pinned kwt".utf8).write(to: helperURL)
        defer { try? FileManager.default.removeItem(at: helperURL) }
        let recorder = KwtInstallRecorder()
        let installer = KwtRemoteInstaller(
            revision: revision,
            remoteRunner: { _, _, command in
                recorder.record(command: command)
                if command == KwtRemoteInstaller.targetProbeCommand {
                    return installOutput(
                        0,
                        "GHOSTHUB_KWT_TARGET\tLinux\tx86_64\n"
                    )
                }
                if command.contains("GHOSTHUB_KWT_UPLOAD") {
                    return installOutput(
                        0,
                        "GHOSTHUB_KWT_UPLOAD\t/home/user-a/.ghosthub/"
                            + "helpers/kwt/\(revision)/.incoming-test\n"
                    )
                }
                if command.contains("GHOSTHUB_KWT_INSTALLED") {
                    return installOutput(255)
                }
                return installOutput(0)
            },
            uploadRunner: { _, _, _, _ in installOutput(0) },
            resourceProvider: { _ in helperURL }
        )

        await #expect {
            try await installer.install(on: SSHHost(
                configKey: "linux-build",
                name: "Linux Build Host",
                platform: .linux,
                sshDestination: "operator@build.example.test"
            ))
        } throws: {
            $0 as? KwtRemoteInstallError == .installFailed(status: 255)
        }

        let cleanupCommand = try #require(recorder.commands.last)
        #expect(cleanupCommand.contains("rm -f"))
        #expect(cleanupCommand.contains(revision))
        #expect(cleanupCommand.contains(".incoming-"))
    }

    @Test("remote installation invalidates a dead pooled connection")
    func remoteInstallInvalidatesDeadConnection() async {
        let invalidations = LockedValue(0)
        let installer = KwtRemoteInstaller(
            revision: String(repeating: "a", count: 40),
            remoteRunner: { _, _, _ in
                AccountCommandOutput(
                    status: 255,
                    stdout: "",
                    stderr:
                    "Control socket connect(/tmp/dead.sock): No such file or directory"
                )
            },
            commandLease: KwtSSHCommandLease { _ in
                KwtSSHConnection(
                    arguments: ["-S", "/tmp/dead.sock"],
                    routeIdentity: "reviewed-route",
                    generation: 3,
                    invalidate: {
                        invalidations.withLock { $0 += 1 }
                    }
                )
            }
        )

        await #expect {
            try await installer.install(on: SSHHost(
                configKey: "builder",
                name: "Builder",
                platform: .linux,
                sshDestination: "dev@builder.example.test"
            ))
        } throws: { error in
            error as? KwtRemoteInstallError
                == .targetProbeFailed(status: 255)
        }
        #expect(invalidations.load() == 1)
    }
}

private func installOutput(
    _ status: Int32,
    _ stdout: String = "",
    stderr: String = ""
) -> AccountCommandOutput {
    AccountCommandOutput(
        status: status,
        stdout: stdout,
        stderr: stderr
    )
}

private final class KwtInstallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCommands: [String] = []
    private var storedHost: SSHHostInfo?
    private var storedSource: URL?
    private var storedDestination: String?

    var commands: [String] { lock.withLock { storedCommands } }
    var host: SSHHostInfo? { lock.withLock { storedHost } }
    var source: URL? { lock.withLock { storedSource } }
    var destination: String? { lock.withLock { storedDestination } }

    func record(command: String) {
        lock.withLock {
            storedCommands.append(command)
        }
    }

    func record(
        host: SSHHostInfo,
        source: URL,
        destination: String
    ) {
        lock.withLock {
            storedHost = host
            storedSource = source
            storedDestination = destination
        }
    }
}
