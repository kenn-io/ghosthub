import GhosthubTransport
import Foundation
import GhosthubSettings
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("Windows kwt installation")
struct KwtWindowsInstallerTests {
    @Test("SCP reuses authentication and preserves an explicit port")
    func reusesAuthenticationForTransfer() throws {
        let arguments = KwtWindowsInstaller.transferArguments(
            host: SSHHostInfo(
                user: "developer",
                hostname: "windows-node.example.test",
                port: 22,
                platform: .windows
            ),
            localPath: "/tmp/kwt.exe",
            remoteName: "ghosthub-upload.exe",
            connectionArguments: ["-o", "ControlPath=/tmp/control"]
        )

        #expect(arguments.contains(where: { $0.hasPrefix("ControlPath=") }))
        let portIndex = try #require(arguments.firstIndex(of: "-P"))
        #expect(arguments[portIndex + 1] == "22")
    }

    @Test("SCP translates the kwt SSH projection port option")
    func translatesProjectedPortForTransfer() throws {
        let arguments = KwtWindowsInstaller.transferArguments(
            host: SSHHostInfo(
                user: "developer",
                hostname: "windows-node.example.test",
                port: nil,
                platform: .windows
            ),
            localPath: "/tmp/kwt.exe",
            remoteName: "ghosthub-upload.exe",
            connectionArguments: ["-F", "NUL", "-p", "2200"]
        )

        #expect(!arguments.contains("-p"))
        let portIndex = try #require(arguments.firstIndex(of: "-P"))
        #expect(arguments[portIndex + 1] == "2200")
    }

    @Test("installs the matching bundled helper at the managed path")
    func installsArm64Helper() async throws {
        let revision = String(repeating: "a", count: 40)
        let managedPath = try #require(
            KwtBinaryLocator.windowsRemoteManagedRelativePath(
                revision: revision
            )
        )
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
            revision: revision,
            remoteRunner: { host, _, command in
                #expect(host.platform == .windows)
                if command.contains("OSArchitecture") {
                    return AccountCommandOutput(
                        status: 0,
                        stdout:
                        "banner without newline"
                            + "GHOSTHUB_WINDOWS_ARCH=Arm64\r\n",
                        stderr: ""
                    )
                }
                #expect(command.contains(
                    powerShellEncodedArgument(managedPath)
                ))
                #expect(command.contains(
                    powerShellEncodedArgument("ghosthub-upload.exe")
                ))
                #expect(command.contains("Get-FileHash"))
                #expect(command.contains("-Algorithm SHA256"))
                #expect(command.contains("$ghosthubDigest -cne "))
                #expect(command.contains(
                    powerShellEncodedArgument(
                        "kwt version \(revision)"
                    )
                ))
                #expect(command.contains("[System.IO.File]::Replace"))
                #expect(command.contains("$ghosthubBackup"))
                let stagedVerification = command.range(
                    of: "& $ghosthubStaging 'version'"
                )?.lowerBound
                let digestVerification = command.range(
                    of: "Get-FileHash"
                )?.lowerBound
                let replacement = command.range(
                    of: "[System.IO.File]::Replace("
                )?.lowerBound
                #expect(stagedVerification != nil)
                #expect(digestVerification != nil)
                #expect(replacement != nil)
                if let stagedVerification,
                   let digestVerification,
                   let replacement {
                    #expect(stagedVerification < replacement)
                    #expect(digestVerification < replacement)
                }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_KWT_INSTALLED\n",
                    stderr: ""
                )
            },
            transferRunner: { host, localPath, remoteName, _ in
                #expect(host.hostname == "arm-builder")
                #expect(localPath == helperURL.path)
                #expect(remoteName == "ghosthub-upload.exe")
                return AccountCommandOutput(status: 0, stdout: "", stderr: "")
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
            revision: String(repeating: "b", count: 40),
            remoteRunner: { _, _, _ in
                AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_WINDOWS_ARCH=RISCV64\n",
                    stderr: ""
                )
            },
            transferRunner: { _, _, _, _ in
                Issue.record("unsupported architecture must not upload")
                return AccountCommandOutput(status: 0, stdout: "", stderr: "")
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

    @Test("a dead installer connection invalidates its pooled generation")
    func invalidatesDeadConnection() async {
        let invalidations = LockedValue(0)
        let installer = KwtWindowsInstaller(
            revision: String(repeating: "c", count: 40),
            remoteRunner: { _, _, _ in
                AccountCommandOutput(
                    status: 255,
                    stdout: "",
                    stderr: "Control socket connect(/tmp/dead): No such file"
                )
            },
            transferRunner: { _, _, _, _ in
                Issue.record("a failed architecture probe must not upload")
                return AccountCommandOutput(status: 0, stdout: "", stderr: "")
            },
            commandLease: KwtSSHCommandLease { _ in
                testKwtSSHAttachment(invalidate: {
                    invalidations.withLock { $0 += 1 }
                })
            }
        )

        let result = await installer.install(on: SSHHost(
            configKey: "dead-builder",
            name: "Dead Builder",
            platform: .windows,
            sshDestination: "dead-builder"
        ))

        guard case let .failure(error) = result else {
            Issue.record("expected architecture probe failure")
            return
        }
        #expect(error == .architectureProbeFailed(status: 255))
        #expect(invalidations.load() == 1)
    }
}
