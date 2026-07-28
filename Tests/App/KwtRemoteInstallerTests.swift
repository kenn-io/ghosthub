import CryptoKit
import Foundation
import GhosthubSettings
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("Managed remote kwt installation")
struct KwtRemoteInstallerTests {
    @Test("Linux arm64 helper is verified and installed by exact revision")
    func installsLinuxARM64Helper() async throws {
        let revision = String(repeating: "d", count: 40)
        let helperURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("pinned kwt".utf8).write(to: helperURL)
        defer { try? FileManager.default.removeItem(at: helperURL) }
        let recorder = KwtInstallRecorder()
        let installer = KwtRemoteInstaller(
            revision: revision,
            remoteRunner: { _, command in
                recorder.record(command: command)
                if command == KwtRemoteInstaller.targetProbeCommand {
                    return (
                        0,
                        "banner\nGHOSTHUB_KWT_TARGET\tLinux\taarch64\n"
                    )
                }
                if command.contains("GHOSTHUB_KWT_UPLOAD") {
                    return (
                        0,
                        "GHOSTHUB_KWT_UPLOAD\t/home/wesm/.ghosthub/"
                            + "helpers/kwt/\(revision)/.incoming-test\n"
                    )
                }
                return (0, "GHOSTHUB_KWT_INSTALLED\n")
            },
            uploadRunner: { host, source, destination in
                recorder.record(
                    host: host,
                    source: source,
                    destination: destination
                )
                return (0, "")
            },
            resourceProvider: { target in
                #expect(target == .linuxARM64)
                return helperURL
            }
        )

        try await installer.install(on: SSHHost(
            configKey: "spark",
            name: "DGX Spark",
            platform: .linux,
            sshDestination: "wesm@spark:2222"
        ))

        #expect(recorder.host == SSHHostInfo(
            user: "wesm",
            hostname: "spark",
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
            target: .linuxAMD64,
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
                user: "wesm",
                hostname: "home-nuc",
                port: nil
            ),
            source: URL(fileURLWithPath: "/tmp/pinned kwt"),
            destination:
            "/home/wesm/.ghosthub/helpers/kwt/revision/.incoming-test"
        )

        #expect(
            arguments.last
                == "wesm@home-nuc:/home/wesm/.ghosthub/helpers/"
                + "kwt/revision/.incoming-test"
        )
    }

    @Test("SCP brackets an IPv6 host while preserving its username")
    func bracketsIPv6Destination() {
        let arguments = KwtRemoteInstaller.uploadArguments(
            host: SSHHostInfo(
                user: "wesm",
                hostname: "2001:db8::42",
                port: nil
            ),
            source: URL(fileURLWithPath: "/tmp/kwt"),
            destination: "/home/wesm/.ghosthub/helpers/kwt"
        )

        #expect(
            arguments.last
                == "wesm@[2001:db8::42]:/home/wesm/.ghosthub/helpers/kwt"
        )
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
            remoteRunner: { _, command in
                recorder.record(command: command)
                if command == KwtRemoteInstaller.targetProbeCommand {
                    return (
                        0,
                        "GHOSTHUB_KWT_TARGET\tLinux\tx86_64\n"
                    )
                }
                return (
                    0,
                    "GHOSTHUB_KWT_UPLOAD\t/home/wesm/.ghosthub/"
                        + "helpers/kwt/\(revision)/.incoming-test\n"
                )
            },
            uploadRunner: { _, _, _ in
                (1, "scp: destination is unavailable\n")
            },
            resourceProvider: { _ in helperURL }
        )

        await #expect {
            try await installer.install(on: SSHHost(
                configKey: "nuc",
                name: "Home NUC",
                platform: .linux,
                sshDestination: "wesm@home-nuc"
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
            remoteRunner: { _, command in
                recorder.record(command: command)
                if command == KwtRemoteInstaller.targetProbeCommand {
                    return (
                        0,
                        "GHOSTHUB_KWT_TARGET\tLinux\tx86_64\n"
                    )
                }
                if command.contains("GHOSTHUB_KWT_UPLOAD") {
                    return (
                        0,
                        "GHOSTHUB_KWT_UPLOAD\t/home/wesm/.ghosthub/"
                            + "helpers/kwt/\(revision)/.incoming-test\n"
                    )
                }
                if command.contains("GHOSTHUB_KWT_INSTALLED") {
                    return (255, "")
                }
                return (0, "")
            },
            uploadRunner: { _, _, _ in (0, "") },
            resourceProvider: { _ in helperURL }
        )

        await #expect {
            try await installer.install(on: SSHHost(
                configKey: "nuc",
                name: "Home NUC",
                platform: .linux,
                sshDestination: "wesm@home-nuc"
            ))
        } throws: {
            $0 as? KwtRemoteInstallError == .installFailed(status: 255)
        }

        let cleanupCommand = try #require(recorder.commands.last)
        #expect(cleanupCommand.contains("rm -f"))
        #expect(cleanupCommand.contains(revision))
        #expect(cleanupCommand.contains(".incoming-"))
    }
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
