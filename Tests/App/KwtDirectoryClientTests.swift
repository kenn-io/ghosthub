import Foundation
import GhosthubSettings
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("kwt directory client")
struct KwtDirectoryClientTests {
    @Test("reads directory JSON after login output")
    func listing() async throws {
        let client = KwtDirectoryClient(runner: { _ in
            AccountCommandOutput(status: 0, stdout: """
            login banner
            GHOSTHUB_DIRECTORY_JSON
            {"path":"/hub","entries":[{"name":"widget","path":"/hub/widget","project_path":"/hub/widget/main"}],"truncated":false}
            """, stderr: "")
        })
        let result = try await client.browse("/hub", on: .local)
        #expect(result.entries.first?.projectPath == "/hub/widget/main")
    }

    @Test("rejects failed commands and invalid listings", arguments: [
        (Int32(1), ""),
        (Int32(0), "not JSON"),
        (Int32(0), #"{"path":"/hub","entries":[{"name":"..","path":"/"}],"truncated":false}"#),
        (
            Int32(0),
            #"{"path":"/hub","entries":[{"name":"other","path":"/elsewhere"}],"truncated":false}"#
        ),
    ])
    func invalid(status: Int32, json: String) async {
        let client = KwtDirectoryClient(runner: { _ in
            AccountCommandOutput(
                status: status, stdout: "GHOSTHUB_DIRECTORY_JSON\n" + json, stderr: ""
            )
        })
        await #expect(throws: HostProbeError.self) {
            try await client.browse("/hub", on: .local)
        }
    }

    @Test("rejects relative paths before running a command")
    func relativePath() async {
        let client = KwtDirectoryClient(runner: { _ in
            Issue.record("Invalid paths must not invoke kwt")
            return AccountCommandOutput(status: 0, stdout: "", stderr: "")
        })
        await #expect(throws: HostProbeError.self) {
            try await client.register("relative", on: .local)
        }
    }

    @Test("directory registration never expands dollar signs from a selected path")
    func literalDollarPath() async {
        let client = KwtDirectoryClient(runner: { _ in
            Issue.record("kwt expands dollar signs when storing directory paths")
            return AccountCommandOutput(status: 0, stdout: "", stderr: "")
        })
        await #expect(throws: HostProbeError.self) {
            try await client.register("/hub/$HOME", on: .local)
        }
    }
}
