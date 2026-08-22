import Darwin
import Foundation
import GhosthubTestSupport
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("kwt SSH connection leases")
struct KwtSSHLeaseClientTests {
    @Test("lease acquisition uses Ghosthub-owned kwt daemon state")
    func isolatesDaemonState() async throws {
        let fixture = try TempDirectoryFixture()
        let kwtHome = StateHome.resolved()
            .appendingPathComponent("ssh", isDirectory: true)
            .appendingPathComponent("kwt", isDirectory: true)
        let helper = try fixture.createExecutable(
            name: "kwt",
            content: """
            #!/bin/sh
            [ "${KWT_HOME:-}" = \(shellQuotedCommandArgument(kwtHome.path)) ] || exit 90
            printf '%s\n' '{"operation_id":"operation-1","sequence":1,"kind":"complete","result":{"lease_id":"lease-1","route_identity":"sha256:route-observation","generation":42,"mode":"multiplexed","arguments":["-S","/tmp/control"]}}'
            """
        )

        let lease = try await KwtSSHLeaseClient(
            binaryPath: helper.path
        ).acquire(route: Self.route, prompt: { _ in "" })

        #expect(lease.result.routeIdentity == Self.route.routeIdentity)
    }

    @Test("times out a silent lease helper")
    func timesOutSilentHelper() async throws {
        let fixture = try TempDirectoryFixture()
        let childPID = fixture.childURL("child-pid")
        let helper = try fixture.createExecutable(
            name: "kwt",
            content: "#!/bin/sh\nsleep 30 &\nprintf '%s\\n' \"$!\" > "
                + shellQuotedCommandArgument(childPID.path)
                + "\nwait\n"
        )

        let client = KwtSSHLeaseClient(
            binaryPath: helper.path,
            inactivityTimeout: .milliseconds(100)
        )
        let startedAt = ContinuousClock.now
        await #expect(throws: KwtSSHLeaseError.acquisitionTimedOut) {
            _ = try await client.acquire(route: Self.route, prompt: { _ in "" })
        }
        #expect(ContinuousClock.now - startedAt < .seconds(5))
        if let contents = try? String(contentsOf: childPID, encoding: .utf8),
           let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    @Test("cancellation promptly terminates a silent acquisition helper")
    func cancelsSilentAcquisition() async throws {
        let fixture = try TempDirectoryFixture()
        let pidFile = fixture.childURL("pid")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$$\" > "
            + shellQuotedCommandArgument(pidFile.path)
            + "\nsleep 30\n"
        let helper = try fixture.createExecutable(name: "kwt", content: script)
        let task = Task {
            try await KwtSSHLeaseClient(
                binaryPath: helper.path,
                inactivityTimeout: .seconds(30)
            ).acquire(route: Self.route, prompt: { _ in "" })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: pidFile.path),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try #require(FileManager.default.fileExists(atPath: pidFile.path))
        let pid = try #require(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { _ = Darwin.kill(pid, SIGKILL) }

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let exitDeadline = ContinuousClock.now + .seconds(1)
        while Darwin.kill(pid, 0) == 0, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Darwin.kill(pid, 0) != 0)
    }

    @Test("rejects a masterless presentation lease with a stable error")
    func rejectsMasterlessLease() async throws {
        let fixture = try TempDirectoryFixture()
        let script = #"""
        #!/bin/sh
        printf '%s\n' '{"operation_id":"operation-1","sequence":1,"kind":"complete","result":{"lease_id":"lease-1","route_identity":"sha256:route-observation","generation":42,"mode":"masterless","arguments":["-F","/dev/null"]}}'
        """#
        let helper = try fixture.createExecutable(name: "kwt", content: script)

        await #expect(throws: KwtSSHLeaseError.persistentUnsupported) {
            _ = try await KwtSSHLeaseClient(binaryPath: helper.path).acquire(
                route: Self.route,
                prompt: { _ in "" }
            )
        }
    }

    @Test(
        "rejects lease arguments outside the reviewed projection contract",
        arguments: [
            ["build.example.test"],
            ["--", "build.example.test"],
            ["-p", "2200"],
            ["-S"],
            ["-o", "HostName=other.example.test"],
            ["-o", "ProxyCommand=ssh other.example.test"],
        ]
    )
    func rejectsUnsafeLeaseArguments(_ arguments: [String]) async throws {
        let fixture = try TempDirectoryFixture()
        let encoded = try #require(String(
            data: JSONSerialization.data(withJSONObject: arguments),
            encoding: .utf8
        ))
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"operation_id":"operation-1","sequence":1,"kind":"complete","result":{"lease_id":"lease-1","route_identity":"sha256:route-observation","generation":42,"mode":"multiplexed","arguments":\(
            encoded
        )}}'
        """
        let helper = try fixture.createExecutable(name: "kwt", content: script)

        await #expect(throws: KwtSSHLeaseError.malformedEvent) {
            _ = try await KwtSSHLeaseClient(binaryPath: helper.path).acquire(
                route: Self.route,
                prompt: { _ in "" }
            )
        }
    }

    @Test("maps configuration-change completions to route changes")
    func mapsConfigurationChangeCompletion() async throws {
        let fixture = try TempDirectoryFixture()
        let script = #"""
        #!/bin/sh
        printf '%s\n' '{"operation_id":"operation-1","sequence":1,"kind":"complete","failure":{"code":"ssh_configuration_changed","message":"SSH configuration changed","retryable":true}}'
        """#
        let helper = try fixture.createExecutable(name: "kwt", content: script)

        await #expect(throws: KwtSSHLeaseError.routeChanged) {
            _ = try await KwtSSHLeaseClient(binaryPath: helper.path).acquire(
                route: Self.route,
                prompt: { _ in "" }
            )
        }
    }

    @Test("reports a typed lifecycle failure after lease readiness")
    func reportsPostReadinessFailure() async throws {
        let fixture = try TempDirectoryFixture()
        let script = #"""
        #!/bin/sh
        printf '%s\n' '{"operation_id":"operation-1","sequence":1,"kind":"complete","result":{"lease_id":"lease-1","route_identity":"sha256:route-observation","generation":42,"mode":"multiplexed","arguments":["-S","/tmp/control"]}}'
        sleep 0.1
        printf '%s\n' '{"error":{"code":"ssh_connection_changed","message":"SSH connection changed","retryable":false}}'
        exit 1
        """#
        let helper = try fixture.createExecutable(name: "kwt", content: script)

        let lease = try await KwtSSHLeaseClient(binaryPath: helper.path).acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        #expect(
            await lease.terminalFailure.value
                == .operationFailed(
                    code: "ssh_connection_changed",
                    message: "SSH connection changed",
                    retryable: false
                )
        )
    }

    @Test("treats an unsolicited clean helper exit as lease failure")
    func reportsUnsolicitedCleanExit() async throws {
        let fixture = try TempDirectoryFixture()
        let script = #"""
        #!/bin/sh
        printf '%s\n' '{"operation_id":"operation-1","sequence":1,"kind":"complete","result":{"lease_id":"lease-1","route_identity":"sha256:route-observation","generation":42,"mode":"multiplexed","arguments":["-S","/tmp/control"]}}'
        exit 0
        """#
        let helper = try fixture.createExecutable(name: "kwt", content: script)

        let lease = try await KwtSSHLeaseClient(binaryPath: helper.path).acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        #expect(
            await lease.terminalFailure.value == .operationFailed(
                code: "ssh_connection_changed",
                message: "The SSH lease helper exited unexpectedly.",
                retryable: false
            )
        )
    }

    @Test("streams bound prompts and releases the daemon lease on close")
    func streamsPromptsAndReleases() async throws {
        let fixture = try TempDirectoryFixture()
        let helper = try fixture.createExecutable(
            name: "kwt",
            content: Self.helperScript
        )
        let responses = fixture.childURL("responses")
        let released = fixture.childURL("released")
        let arguments = fixture.childURL("arguments")

        let prompts = LockedValue<[KwtSSHLeasePrompt]>([])
        let client = KwtSSHLeaseClient(binaryPath: helper.path)
        let route = Self.route
        let lease = try await client.acquire(
            route: route,
            prompt: { prompt in
                prompts.withLock { $0.append(prompt) }
                return prompt.id == "password" ? "secret" : "123456"
            }
        )

        #expect(lease.result.routeIdentity == route.routeIdentity)
        #expect(lease.result.generation == 42)
        #expect(lease.result.mode == .multiplexed)
        #expect(lease.result.arguments == Self.validLeaseArguments)
        #expect(prompts.load().map(\.id) == ["password", "verification"])
        let receivedPrompts = prompts.load()
        #expect(receivedPrompts.map(\.kind) == [
            .authentication, .hostKey,
        ])
        #expect(receivedPrompts.map(\.sensitive) == [true, false])
        #expect(receivedPrompts[0].deadline == "2026-08-14T12:02:00Z")
        #expect(receivedPrompts[0].details == KwtSSHLeasePromptDetails(
            logicalTarget: KwtSSHTarget(hostname: "build.example.test"),
            effectiveTarget: KwtSSHTarget(
                hostname: "100.64.0.8",
                user: "deploy",
                port: 2200
            ),
            displayTarget: "deploy@build.example.test:2200",
            hopIndex: 0,
            hopCount: 1,
            hostKey: nil
        ))
        #expect(receivedPrompts[1].details.hostKey == KwtSSHHostKeyReview(
            host: "build.example.test (100.64.0.8)",
            algorithm: "ED25519",
            fingerprint: "SHA256:fixture"
        ))
        #expect(
            try String(contentsOf: arguments, encoding: .utf8)
                .split(separator: "\n").map(String.init) == [
                    "ssh", "lease", "--json",
                    "--route-identity", "sha256:route-observation",
                    "--projection-policy", "kwt.openssh.projection.v1",
                    "--host-key-policy", "review",
                    "--user", "deploy", "--port", "2200",
                    "build.example.test",
                ]
        )
        let responseLines = try String(contentsOf: responses, encoding: .utf8)
            .split(separator: "\n")
        #expect(responseLines.count == 2)
        for (line, expectedID) in zip(responseLines, ["password", "verification"]) {
            let response = try JSONDecoder().decode(
                KwtSSHLeasePromptResponse.self,
                from: Data(line.utf8)
            )
            #expect(response.promptID == expectedID)
        }

        try await lease.release()
        #expect(FileManager.default.fileExists(atPath: released.path))
    }

    @Test(
        "rejects prompt metadata that is not bound to the reviewed route",
        arguments: InvalidPrompt.allCases
    )
    func rejectsInvalidPrompt(_ invalidPrompt: InvalidPrompt) async throws {
        let fixture = try TempDirectoryFixture()
        let script = invalidPrompt.apply(to: Self.helperScript)
        let helper = try fixture.createExecutable(name: "kwt", content: script)

        let client = KwtSSHLeaseClient(binaryPath: helper.path)
        await #expect(throws: KwtSSHLeaseError.malformedEvent) {
            _ = try await client.acquire(
                route: Self.route,
                prompt: { _ in "" }
            )
        }
    }

    @Test("cancellation terminates a helper after release starts")
    func cancellationTerminatesReleaseHelper() async throws {
        let fixture = try TempDirectoryFixture()
        let pidFile = fixture.childURL("pid")
        let script = Self.stalledReleaseHelperScript.replacingOccurrences(
            of: "PID_FILE",
            with: shellQuotedCommandArgument(pidFile.path)
        )
        let helper = try fixture.createExecutable(name: "kwt", content: script)
        let lease = try await KwtSSHLeaseClient(binaryPath: helper.path).acquire(
            route: Self.route,
            prompt: { _ in "" }
        )
        let pid = try #require(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { _ = Darwin.kill(pid, SIGKILL) }

        let release = Task {
            try await lease.release(timeout: .seconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        release.cancel()
        await #expect(throws: CancellationError.self) {
            try await release.value
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while Darwin.kill(pid, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(Darwin.kill(pid, 0) != 0)
        try await lease.release(timeout: .seconds(1))
    }

    @Test("terminal helper failures remain observable after release")
    func preservesTerminalReleaseFailure() async throws {
        let fixture = try TempDirectoryFixture()
        let script = #"""
        #!/bin/sh
        set -eu
        printf '%s\n' '{"operation_id":"operation-1","sequence":1,"kind":"complete","result":{"lease_id":"lease-1","route_identity":"sha256:route-observation","generation":42,"mode":"multiplexed","arguments":["-S","/tmp/control"]}}'
        cat >/dev/null
        exit 17
        """#
        let helper = try fixture.createExecutable(name: "kwt", content: script)
        let lease = try await KwtSSHLeaseClient(binaryPath: helper.path).acquire(
            route: Self.route,
            prompt: { _ in "" }
        )

        for _ in 0 ..< 2 {
            await #expect(throws: KwtSSHLeaseError.commandFailed(status: 17)) {
                try await lease.release(timeout: .seconds(1))
            }
        }
    }

    enum InvalidPrompt: CaseIterable, Sendable {
        case hopCount
        case target
        case deadline
        case hostKey

        func apply(to script: String) -> String {
            switch self {
            case .hopCount:
                script.replacingOccurrences(
                    of: #""hop_count":1"#,
                    with: #""hop_count":2"#
                )
            case .target:
                script.replacingOccurrences(
                    of: #""hostname":"100.64.0.8""#,
                    with: #""hostname":"other.example.test""#
                )
            case .deadline:
                script.replacingOccurrences(
                    of: "2026-08-14T12:02:00Z",
                    with: "not-a-deadline"
                )
            case .hostKey:
                script.replacingOccurrences(
                    of: #","host_key":{"host":"build.example.test (100.64.0.8)","algorithm":"ED25519","fingerprint":"SHA256:fixture"}"#,
                    with: ""
                )
            }
        }
    }

    private static let route = KwtSSHRouteSnapshot.fixture(
        logicalTarget: KwtSSHTarget(
            hostname: "build.example.test",
            user: "deploy",
            port: 2200
        ),
        targets: [
            KwtSSHResolvedTarget(
                logicalTarget: KwtSSHTarget(hostname: "build.example.test"),
                effectiveTarget: KwtSSHTarget(
                    hostname: "100.64.0.8",
                    user: "deploy",
                    port: 2200
                ),
                displayTarget: "deploy@build.example.test:2200",
                hostKeyAlias: nil,
                strictHostKeyChecking: "ask",
                projection: KwtSSHExecutionProjection(
                    arguments: ["-F", "/dev/null"],
                    privateConfig: []
                )
            ),
        ],
        routeIdentity: "sha256:route-observation",
        observedAt: "2026-08-14T12:00:00Z"
    )

    private static let helperScript = #"""
    #!/bin/sh
    set -eu
    arguments="$(dirname "$0")/arguments"
    responses="$(dirname "$0")/responses"
    released="$(dirname "$0")/released"
    printf '%s\n' "$@" > "$arguments"
    printf '%s\n' '{"operation_id":"operation-1","sequence":1,"kind":"progress","message":"Preparing SSH connection"}'
    printf '%s\n' '{"operation_id":"operation-1","sequence":2,"kind":"prompt","prompt":{"id":"password","kind":"ssh_authentication","message":"Password:","sensitive":true,"deadline":"2026-08-14T12:02:00Z","details":{"logical_target":{"hostname":"build.example.test"},"effective_target":{"hostname":"100.64.0.8","user":"deploy","port":2200},"display_target":"deploy@build.example.test:2200","hop_index":0,"hop_count":1}}}'
    IFS= read -r response
    printf '%s\n' "$response" >> "$responses"
    printf '%s\n' '{"operation_id":"operation-1","sequence":3,"kind":"prompt","prompt":{"id":"verification","kind":"ssh_host_key","message":"Continue connecting?","sensitive":false,"deadline":"2026-08-14T12:02:00Z","details":{"logical_target":{"hostname":"build.example.test"},"effective_target":{"hostname":"100.64.0.8","user":"deploy","port":2200},"display_target":"deploy@build.example.test:2200","hop_index":0,"hop_count":1,"host_key":{"host":"build.example.test (100.64.0.8)","algorithm":"ED25519","fingerprint":"SHA256:fixture"}}}}'
    IFS= read -r response
    printf '%s\n' "$response" >> "$responses"
    printf '%s\n' '{"operation_id":"operation-1","sequence":4,"kind":"complete","result":{"lease_id":"lease-1","route_identity":"sha256:route-observation","generation":42,"mode":"multiplexed","arguments":["-F","/tmp/session","-o","ForwardAgent=yes","-o","SendEnv=LANG","-o","EscapeChar=~","-o","ControlMaster=no","-o","ControlPersist=no","-S","/tmp/control","-o","BatchMode=yes","-o","ProxyCommand=/usr/bin/false"]}}'
    cat >/dev/null
    printf released > "$released"
    """#

    private static let validLeaseArguments = [
        "-F", "/tmp/session",
        "-o", "ForwardAgent=yes",
        "-o", "SendEnv=LANG",
        "-o", "EscapeChar=~",
        "-o", "ControlMaster=no",
        "-o", "ControlPersist=no",
        "-S", "/tmp/control",
        "-o", "BatchMode=yes",
        "-o", "ProxyCommand=/usr/bin/false",
    ]

    private static let stalledReleaseHelperScript = #"""
    #!/bin/sh
    set -eu
    printf '%s\n' "$$" > PID_FILE
    printf '%s\n' '{"operation_id":"operation-1","sequence":1,"kind":"complete","result":{"lease_id":"lease-1","route_identity":"sha256:route-observation","generation":42,"mode":"multiplexed","arguments":["-S","/tmp/control"]}}'
    cat >/dev/null
    sleep 30
    """#
}
