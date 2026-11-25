import Foundation
import GhosthubSettings
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("kwt directory client")
struct KwtDirectoryClientTests {
    private func workspace(
        _ name: String = "notes",
        path: String = "/hub/notes"
    ) -> DirectoryWorkspaceSummary {
        DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: UUID(),
            name: name,
            path: path,
            tmuxSessionName: "notes",
            sessionLive: false
        )
    }

    @Test(
        "removal rechecks route and registration on the removal lease",
        arguments: ["unchanged", "route", "path", "missing"]
    )
    func removalIdentity(change: String) async throws {
        let directory = workspace()
        let originalJSON = String(
            decoding: try JSONEncoder().encode([KwtDirectoryWorkspaceRecord(directory)]),
            as: UTF8.self
        )
        let currentJSON = LockedValue(originalJSON)
        let route = LockedValue("original")
        let calls = LockedValue([String]())
        let acquisitions = LockedValue(0)
        let client = KwtDirectoryClient(
            remoteRunner: { _, arguments, command in
                #expect(arguments == [route.load()])
                calls.withLock { $0.append(command) }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_DIRECTORY_JSON\n" + currentJSON.load(),
                    stderr: ""
                )
            },
            commandLease: KwtSSHCommandLease { _ in
                acquisitions.withLock { $0 += 1 }
                return KwtSSHConnection(
                    arguments: [route.load()],
                    routeIdentity: route.load(),
                    generation: 1
                )
            }
        )
        let host = CommandHost.ssh(SSHHostInfo(user: "dev", hostname: "alias", port: nil))
        let reviewedRoute = try await client.prepareRemoval(directory, on: host)
        calls.withLock { $0.removeAll() }
        if change == "route" {
            route.withLock { $0 = "replacement" }
        }
        if change == "path" {
            var replacement = KwtDirectoryWorkspaceRecord(directory)
            replacement.path = "/another/notes"
            let json = String(decoding: try JSONEncoder().encode([replacement]), as: UTF8.self)
            currentJSON.withLock { $0 = json }
        }
        if change == "missing" {
            currentJSON.withLock { $0 = "[]" }
        }
        if change == "unchanged" {
            try await client.unregister(directory, on: host, expectedRouteIdentity: reviewedRoute)
            #expect(calls.load().count == 2)
        } else {
            await #expect(throws: HostProbeError.self) {
                try await client.unregister(
                    directory,
                    on: host,
                    expectedRouteIdentity: reviewedRoute
                )
            }
            #expect(calls.load().count == (change == "route" ? 0 : 1))
        }
        #expect(acquisitions.load() == 2)
    }

    @Test(
        "directory removal preserves literal names over local and SSH command paths",
        arguments: [false, true]
    )
    func removalArguments(remote: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "-notes ' $(printf injected)"
        let registration = workspace(name)
        let json = String(
            decoding: try JSONEncoder().encode([KwtDirectoryWorkspaceRecord(registration)]),
            as: UTF8.self
        )
        let helper = directory.appendingPathComponent("kwt")
        try ("#!/bin/sh\nif [ \"$2\" = list ]; then printf '%s' " +
            shellQuotedCommandArgument(json) + "; else printf '%s\\n' \"$@\"; fi\n").write(
            to: helper,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let observed = LockedValue("")
        let run: KwtDirectoryClient.Runner = { command in
            let output = AccountCommandRunner().runLocalLoginShell(command: command, timeout: 10)
            observed.withLock { $0 = output.stdout }
            return output
        }
        let client = KwtDirectoryClient(
            runner: run,
            remoteRunner: { _, arguments, command in
                #expect(arguments == ["fixture-route"])
                // Replace only helper resolution; execute the generated operation in a real shell.
                let operation = command
                    .components(separatedBy: "printf 'GHOSTHUB_DIRECTORY_JSON\\n'; ").last!
                return run(
                    "ghosthub_kwt_path=\(shellQuotedCommandArgument(helper.path)); printf 'GHOSTHUB_DIRECTORY_JSON\\n'; " +
                        operation
                )
            },
            commandLease: KwtSSHCommandLease { _ in
                KwtSSHConnection(
                    arguments: ["fixture-route"],
                    routeIdentity: "fixture",
                    generation: 1
                )
            },
            binaryPath: helper.path
        )
        try await client.unregister(
            registration,
            on: remote ? .ssh(SSHHostInfo(user: "dev", hostname: "builder", port: nil)) : .local,
            expectedRouteIdentity: remote ? "fixture" : nil
        )
        #expect(observed.load().hasSuffix("workspace\nremove\n--\n\(name)\n"))
    }

    @Test("directory removal reports helper failure")
    func removalFailure() async {
        let client = KwtDirectoryClient(runner: { _ in
            AccountCommandOutput(status: 1, stdout: "", stderr: "registration is unavailable")
        })
        do {
            try await client.unregister(workspace(), on: .local, expectedRouteIdentity: nil)
            Issue.record("Removal should fail")
        } catch let error as HostProbeError {
            #expect(error.displayMessage == "registration is unavailable")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

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
