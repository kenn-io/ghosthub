import Foundation
import GhosthubTerminal
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("Remote image paste SSH integration", .serialized)
struct TmuxImagePasterLiveIntegrationTests {
    @Test("uploads exact image bytes through the fixture SSH route")
    func uploadsImageThroughFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GHOSTHUB_RUN_LIVE_INTEGRATION_TESTS"] == "1",
              environment["GHOSTHUB_REQUIRE_SSH_INTERACTION_FIXTURE"] == "1"
        else { return }
        let destination = try #require(
            environment["GHOSTHUB_SSH_INTEGRATION_DESTINATION"]
        )
        let sshConfig = try #require(
            environment["GHOSTHUB_TEST_SSH_CONFIG"]
        )
        let host = try #require(
            CommandHostResolver.parseSSHDestination(destination)
        )
        let fileName = "paste-live-\(UUID().uuidString.lowercased()).png"
        let image = TerminalClipboardImage(pngData: Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0xFF, 0x7F,
        ]))
        let result = await TmuxImagePaster(
            fileNameProvider: { fileName }
        ).paste(
            image,
            on: host,
            connectionArguments: ["-F", sshConfig]
        )
        let remotePath = try result.get()
        let expectedPath = "/home/ghosthub/.ghosthub/paste-images/\(fileName)"
        #expect(remotePath == expectedPath)
        defer {
            _ = AccountCommandRunner().runRemoteLoginShell(
                host: host,
                connectionArguments: ["-F", sshConfig],
                command: "rm -f -- \(shellQuotedCommandArgument(remotePath))",
                timeout: 15
            )
        }

        let imageDirectory = (remotePath as NSString).deletingLastPathComponent
        let inspection = AccountCommandRunner().runRemoteLoginShell(
            host: host,
            connectionArguments: ["-F", sshConfig],
            command: """
            stat -c '%a' -- \(shellQuotedCommandArgument(imageDirectory))
            stat -c '%a' -- \(shellQuotedCommandArgument(remotePath))
            od -An -v -t x1 -- \(shellQuotedCommandArgument(remotePath)) | tr -d ' \n'
            printf '\n'
            """,
            timeout: 15
        )

        #expect(inspection.status == 0, Comment(rawValue: inspection.stderr))
        #expect(inspection.stdout == "700\n600\n89504e470d0a1a0a00ff7f\n")
    }
}
