import Foundation
import GhosthubSettings
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("kwt directory client")
struct KwtDirectoryClientTests {
    @Test(
        "remote listings retain lease identity and reject registration after route changes",
        arguments: [false, true]
    )
    func routeIdentity(changed: Bool) async throws {
        let host = CommandHost.ssh(SSHHostInfo(user: "dev", hostname: "builder", port: nil))
        let route = LockedValue("original")
        let commands = LockedValue(0)
        let client = KwtDirectoryClient(
            remoteRunner: { _, _, _ in
                commands.withLock { $0 += 1 }
                return AccountCommandOutput(status: 0, stdout: """
                GHOSTHUB_DIRECTORY_JSON
                {"path":"/hub","entries":[],"truncated":false,"routeIdentity":"forged"}
                """, stderr: "")
            },
            commandLease: KwtSSHCommandLease { _ in
                KwtSSHConnection(arguments: [], routeIdentity: route.load(), generation: 2)
            }
        )
        let listing = try await client.browse("/hub", on: host)
        #expect(listing.routeIdentity == "original")
        if changed {
            route.withLock { $0 = "replacement" }
        }
        if changed {
            await #expect(throws: HostProbeError.self) {
                try await client.register(
                    "/hub/Notes", on: host, expectedRouteIdentity: listing.routeIdentity
                )
            }
            #expect(commands.load() == 1)
        } else {
            try await client.register(
                "/hub/Notes", on: host, expectedRouteIdentity: listing.routeIdentity
            )
            #expect(commands.load() == 2)
        }
        // A directly typed registration deliberately selects the current host.
        try await client.register("/hub/Typed", on: host)
    }

    @Test("valid Unicode-normalization siblings survive listing validation")
    func unicodeNames() async throws {
        let names = ["caf\u{e9}", "cafe\u{301}", "\u{301}notes"]
        let data = try JSONSerialization.data(withJSONObject: [
            "path": "/hub", "truncated": false,
            "entries": names.map { ["name": $0, "path": "/hub/" + $0] },
        ])
        let json = String(decoding: data, as: UTF8.self)
        let client = KwtDirectoryClient(runner: { _ in
            AccountCommandOutput(status: 0, stdout: "GHOSTHUB_DIRECTORY_JSON\n" + json, stderr: "")
        })
        let listing = try await client.browse("/hub", on: .local)
        #expect(listing.entries.map { Array($0.name.utf8) } == names.map { Array($0.utf8) })
        #expect(Set(listing.entries.map(\.id)).count == names.count)
    }

    @Test("real helper output exceeding one MiB is accepted with a bounded budget")
    func largeResponse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = "/" + String(repeating: "long-path/", count: 120)
        let data = try JSONSerialization.data(withJSONObject: [
            "path": parent, "truncated": false,
            "entries": (0 ..< 1000)
                .map { ["name": "folder-\($0)", "path": parent + "folder-\($0)"] },
        ])
        #expect(data.count > 1024 * 1024)
        let json = directory.appendingPathComponent("listing.json")
        try data.write(to: json)
        let helper = directory.appendingPathComponent("kwt")
        try ("#!/bin/sh\nexec /bin/cat " + shellQuotedCommandArgument(json.path) + "\n")
            .write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let listing = try await KwtDirectoryClient(binaryPath: helper.path).browse(
            parent,
            on: .local
        )
        #expect(listing.entries.count == 1000)
    }

    @Test("login shell preserves metacharacters followed by combining marks")
    func literalShellPaths() {
        let path = "/hub/`\u{301}printf injected`/$\u{301}(printf injected)/'\u{301}\"\\"
        let output = AccountCommandRunner().runLocalLoginShell(
            command: "printf '%s' " + shellQuotedCommandArgument(path), timeout: 10
        )
        #expect(output.status == 0)
        #expect(Array(output.stdout.utf8) == Array(path.utf8))
    }

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
