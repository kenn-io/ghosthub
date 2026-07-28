import Foundation
import GhosthubSettings
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("Windows kwt installation")
struct KwtWindowsInstallerTests {
    @Test("installs the matching bundled helper at the managed path")
    func installsArm64Helper() async throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Ghosthub-\(UUID().uuidString).app",
                isDirectory: true
            )
        let helperURL = bundleURL.appendingPathComponent(
            "Contents/Resources/KwtRemote/windows-arm64/kwt"
        )
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("kwt".utf8).write(to: helperURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let installer = KwtWindowsInstaller(
            bundleURL: bundleURL,
            remoteRunner: { host, command in
                #expect(host.platform == .windows)
                if command.contains("OSArchitecture") {
                    return (
                        status: 0,
                        stdout: "GHOSTHUB_WINDOWS_ARCH=Arm64\n"
                    )
                }
                #expect(command.contains(#".ghosthub\bin"#))
                #expect(command.contains("'ghosthub-upload.exe'"))
                #expect(command.contains("'kwt.exe'"))
                return (
                    status: 0,
                    stdout: "GHOSTHUB_KWT_INSTALLED\n"
                )
            },
            transferRunner: { host, localPath, remoteName in
                #expect(host.hostname == "arm-builder")
                #expect(localPath == helperURL.path)
                #expect(remoteName == "ghosthub-upload.exe")
                return 0
            },
            uploadNameProvider: { "ghosthub-upload.exe" }
        )

        let result = await installer.install(on: SSHHost(
            configKey: "arm-builder",
            name: "ARM Builder",
            platform: .windows,
            sshDestination: "wesm@arm-builder"
        ))

        try result.get()
    }

    @Test("rejects a Windows architecture without a bundled target")
    func rejectsUnsupportedArchitecture() async {
        let installer = KwtWindowsInstaller(
            remoteRunner: { _, _ in
                (
                    status: 0,
                    stdout: "GHOSTHUB_WINDOWS_ARCH=RISCV64\n"
                )
            },
            transferRunner: { _, _, _ in
                Issue.record("unsupported architecture must not upload")
                return 0
            }
        )

        let result = await installer.install(on: SSHHost(
            configKey: "future-builder",
            name: "Future Builder",
            platform: .windows,
            sshDestination: "future-builder"
        ))

        guard case let .failure(error) = result else {
            Issue.record("expected unsupported architecture failure")
            return
        }
        #expect(error == .unsupportedArchitecture("RISCV64"))
    }
}
