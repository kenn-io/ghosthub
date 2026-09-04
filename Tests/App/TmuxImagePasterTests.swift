import Foundation
import GhosthubTerminal
import GhosthubTestSupport
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("Remote tmux image paste")
struct TmuxImagePasterTests {
    @Test("allows larger clipboard images more upload time within a cap")
    func uploadTimeoutScalesWithImageSize() {
        #expect(TmuxImagePaster.uploadTimeout(byteCount: 0) == 30)
        #expect(
            TmuxImagePaster.uploadTimeout(byteCount: 10 * 1_024 * 1_024)
                == 190
        )
        #expect(TmuxImagePaster.uploadTimeout(byteCount: .max) == 600)
    }

    @Test("stages image bytes and reports the remote cache path")
    func uploadCommandStagesImage() throws {
        let fixture = try TempDirectoryFixture()
        let input = fixture.childURL("clipboard source.png")
        let imageDirectory = fixture.childURL("paste images")
        let target = imageDirectory.appendingPathComponent("paste-test.png")
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
        try image.write(to: input)
        let command = TmuxImagePaster.uploadCommand(
            fileName: target.lastPathComponent,
            imageDirectory: imageDirectory.path
        )
        let output = AccountCommandRunner().runLocalLoginShell(
            command: """
            (
            \(command)
            ) < \(shellQuotedCommandArgument(input.path))
            """,
            timeout: 10
        )

        #expect(output.status == 0, Comment(rawValue: output.stderr))
        #expect(try Data(contentsOf: target) == image)
        #expect(
            TmuxImagePaster.uploadedPath(
                from: output.stdout,
                fileName: target.lastPathComponent
            ) == target.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: imageDirectory.path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: target.path
        )
        #expect(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o700
        )
        #expect(
            (fileAttributes[.posixPermissions] as? NSNumber)?.intValue
                == 0o600
        )
    }

    @Test("uploads PNG bytes through the frozen SSH route and accepts its path")
    func uploadsImageAndReturnsRemotePath() async throws {
        struct Invocation: Sendable {
            let host: SSHHostInfo
            let connectionArguments: [String]
            let image: Data
            let timeout: TimeInterval
        }
        let invocation = LockedValue<Invocation?>(nil)
        let host = SSHHostInfo(
            user: "dev",
            hostname: "builder.example.test",
            port: 2222
        )
        let image = TerminalClipboardImage(pngData: Data([0x89, 0x50, 0x4E, 0x47]))
        let paster = TmuxImagePaster(
            runner: { host, arguments, _, image, timeout in
                invocation.withLock {
                    $0 = Invocation(
                        host: host,
                        connectionArguments: arguments,
                        image: image,
                        timeout: timeout
                    )
                }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "shell banner\nGHOSTHUB_IMAGE_PASTE\t/home/dev/.ghosthub/paste-images/paste-test.png\n",
                    stderr: ""
                )
            },
            fileNameProvider: { "paste-test.png" }
        )

        let path = try await paster.paste(
            image,
            on: host,
            connectionArguments: ["-F", "/tmp/ghosthub-ssh-config"]
        ).get()

        #expect(path == "/home/dev/.ghosthub/paste-images/paste-test.png")
        #expect(invocation.load()?.host == host)
        #expect(
            invocation.load()?.connectionArguments
                == ["-F", "/tmp/ghosthub-ssh-config"]
        )
        #expect(invocation.load()?.image == image.pngData)
        #expect(
            invocation.load()?.timeout
                == TmuxImagePaster.uploadTimeout(
                    byteCount: image.pngData.count
                )
        )
    }

    @Test("rejects an upload response that does not name the staged image")
    func rejectsUnexpectedRemotePath() async {
        let paster = TmuxImagePaster(
            runner: { _, _, _, _, _ in
                AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_IMAGE_PASTE\t/tmp/different.png\n",
                    stderr: ""
                )
            },
            fileNameProvider: { "paste-test.png" }
        )

        let result = await paster.paste(
            TerminalClipboardImage(pngData: Data([1])),
            on: SSHHostInfo(
                user: nil,
                hostname: "builder.example.test",
                port: nil
            ),
            connectionArguments: []
        )

        guard case let .failure(failure) = result else {
            Issue.record("Expected an invalid upload response")
            return
        }
        #expect(failure.status == 65)
    }
}
