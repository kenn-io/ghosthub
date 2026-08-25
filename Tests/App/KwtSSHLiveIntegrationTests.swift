import Foundation
import GhosthubTestSupport
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("kwt SSH live integration", .serialized)
struct KwtSSHLiveIntegrationTests {
    @Test("pinned kwt owns direct, ProxyJump, and interactive connections")
    func configuredDestinations() async throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        guard processEnvironment["GHOSTHUB_RUN_LIVE_INTEGRATION_TESTS"] == "1"
        else { return }
        let binary = try #require(
            processEnvironment["GHOSTHUB_KWT_CONTRACT_BINARY"]
        )
        let direct = try #require(Self.nonemptyEnvironmentValue(
            "GHOSTHUB_SSH_INTEGRATION_DESTINATION",
            environment: processEnvironment
        ))
        let interactive = Self.nonemptyEnvironmentValue(
            "GHOSTHUB_SSH_INTERACTIVE_INTEGRATION_DESTINATION",
            environment: processEnvironment
        )
        let fixtureMode = processEnvironment[
            "GHOSTHUB_REQUIRE_SSH_INTERACTION_FIXTURE"
        ] == "1"
        if fixtureMode {
            _ = try #require(interactive)
        }
        let destinations: [(
            String,
            String?,
            [String]?,
            [String]?,
            Bool
        )] = [
            (
                "direct",
                direct,
                fixtureMode ? ["ghosthub-direct"] : nil,
                fixtureMode ? ["127.0.0.1"] : nil,
                false
            ),
            (
                "ProxyJump",
                Self.nonemptyEnvironmentValue(
                    "GHOSTHUB_SSH_PROXYJUMP_INTEGRATION_DESTINATION",
                    environment: processEnvironment
                ),
                fixtureMode ? ["ghosthub-relay", "ghosthub-jumped"] : nil,
                fixtureMode ? ["127.0.0.1", "target"] : nil,
                false
            ),
            (
                "interactive ProxyJump",
                interactive,
                fixtureMode ? [
                    "ghosthub-interactive-relay",
                    "ghosthub-interactive-jumped",
                ] : nil,
                fixtureMode ? ["127.0.0.1", "target"] : nil,
                true
            ),
        ].compactMap {
            label,
            destination,
            logicalTargets,
            effectiveTargets,
            answersFixturePrompts in
            destination.map {
                (
                    label,
                    $0,
                    logicalTargets,
                    effectiveTargets,
                    answersFixturePrompts
                )
            }
        }
        let fixture = try TempDirectoryFixture(shortPath: true)
        let kwtHome = if let configuredHome = Self.nonemptyEnvironmentValue(
            "GHOSTHUB_SSH_INTEGRATION_KWT_HOME",
            environment: processEnvironment
        ) {
            configuredHome
        } else {
            try fixture.createSubdirectory("kwt-home").path
        }
        let environment = processEnvironment.merging([
            "KWT_HOME": kwtHome,
        ]) { _, isolated in isolated }
        defer {
            _ = AccountCommandRunner.runProcess(
                executable: binary,
                arguments: ["daemon", "stop"],
                timeout: 10,
                environmentOverrides: environment
            )
        }

        for (
            label,
            destination,
            logicalTargets,
            effectiveTargets,
            answersFixturePrompts
        ) in destinations {
            guard let destination else { continue }
            try await Self.exercise(
                destination: destination,
                binary: binary,
                environment: environment,
                label: label,
                expectedLogicalTargets: logicalTargets,
                expectedEffectiveTargets: effectiveTargets,
                expectedRemoteHostname: fixtureMode
                    ? "ghosthub-target-fixture"
                    : nil,
                answersFixturePrompts: answersFixturePrompts
            )
        }
        if fixtureMode {
            try await Self.verifyUnattendedHostKeyPolicy(
                binary: binary,
                environment: environment,
                destination: try #require(Self.nonemptyEnvironmentValue(
                    "GHOSTHUB_SSH_UNATTENDED_INTEGRATION_DESTINATION",
                    environment: processEnvironment
                )),
                knownHostsPath: try #require(Self.nonemptyEnvironmentValue(
                    "GHOSTHUB_SSH_UNATTENDED_KNOWN_HOSTS",
                    environment: processEnvironment
                ))
            )
        }
    }

    private static func verifyUnattendedHostKeyPolicy(
        binary: String,
        environment: [String: String],
        destination: String,
        knownHostsPath: String
    ) async throws {
        let host = try #require(
            CommandHostResolver.parseSSHDestination(destination)
        )
        let route = try KwtSSHRouteClient(
            runner: { executable, arguments, timeout in
                AccountCommandRunner.runProcess(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    environmentOverrides: environment
                )
            },
            binaryPath: binary
        ).resolve(host)
        do {
            let lease = try await KwtSSHLeaseClient(
                binaryPath: binary,
                environment: environment
            ).acquire(
                route: route,
                hostKeyPolicy: .strict,
                prompt: { _ in
                    Issue.record("Unattended SSH acquisition requested input")
                    throw KwtSSHLeaseError.operationFailed(
                        code: "ssh_interaction_required",
                        message: "Unexpected SSH prompt.",
                        retryable: false
                    )
                }
            )
            try await lease.release()
            Issue.record("Unattended acquisition trusted an unknown host key")
        } catch {
            // A strict lease against an empty known-hosts file must fail.
        }
        let knownHosts = try String(
            contentsOfFile: knownHostsPath,
            encoding: .utf8
        )
        #expect(knownHosts.isEmpty)
    }

    private static func exercise(
        destination: String,
        binary: String,
        environment: [String: String],
        label: String,
        expectedLogicalTargets: [String]?,
        expectedEffectiveTargets: [String]?,
        expectedRemoteHostname: String?,
        answersFixturePrompts: Bool
    ) async throws {
        let host = try #require(
            CommandHostResolver.parseSSHDestination(destination)
        )
        let directArguments: [String] = {
            var arguments = ["-G"]
            if let user = host.user {
                arguments.append(contentsOf: ["-l", user])
            }
            if let port = host.port {
                arguments.append(contentsOf: ["-p", String(port)])
            }
            arguments.append(contentsOf: ["--", host.hostname])
            return arguments
        }()
        var directResolutionMilliseconds: [Double] = []
        for _ in 0 ..< 10 {
            let started = ContinuousClock.now
            let output = AccountCommandRunner.runProcessInLoginShell(
                executable: "ssh",
                arguments: directArguments,
                timeout: 30,
                environmentOverrides: environment
            )
            try #require(output.status == 0)
            directResolutionMilliseconds.append(milliseconds(
                started.duration(to: .now)
            ))
        }

        let routeClient = KwtSSHRouteClient(
            runner: { executable, arguments, timeout in
                AccountCommandRunner.runProcess(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    environmentOverrides: environment
                )
            },
            binaryPath: binary
        )
        let coldResolutionStarted = ContinuousClock.now
        var route = try routeClient.resolve(host)
        let coldResolutionMilliseconds = milliseconds(
            coldResolutionStarted.duration(to: .now)
        )
        var warmResolutionMilliseconds: [Double] = []
        for _ in 0 ..< 10 {
            let started = ContinuousClock.now
            route = try routeClient.resolve(host)
            warmResolutionMilliseconds.append(milliseconds(
                started.duration(to: .now)
            ))
        }
        if let expectedLogicalTargets {
            #expect(
                route.targets.map(\.logicalTarget.hostname)
                    == expectedLogicalTargets
            )
        }
        if let expectedEffectiveTargets {
            #expect(
                route.targets.map(\.effectiveTarget.hostname)
                    == expectedEffectiveTargets
            )
        }
        let rawAcquireCount = LockedValue(0)
        let leaseClient = KwtSSHLeaseClient(
            binaryPath: binary,
            environment: environment
        )
        let pool = KwtSSHConnectionPool { route, prompt in
            rawAcquireCount.withLock { $0 += 1 }
            return try await leaseClient.acquire(
                route: route,
                prompt: prompt
            )
        }
        let prompts = LockedValue<[KwtSSHLeasePrompt]>([])
        let promptCountsByHop = LockedValue<[Int: Int]>([:])
        let isHostReview: @Sendable (KwtSSHLeasePrompt) -> Bool = { prompt in
            prompt.kind == .hostKey && !prompt.sensitive
        }
        let promptHandler: KwtSSHLeaseClient.PromptHandler = { prompt in
            guard answersFixturePrompts else {
                throw KwtSSHLeaseError.operationFailed(
                    code: "ssh_interaction_required",
                    message: "The live destination requires interactive SSH input.",
                    retryable: false
                )
            }
            prompts.withLock { $0.append(prompt) }
            promptCountsByHop.withLock { counts in
                let next = (counts[prompt.details.hopIndex] ?? 0) + 1
                counts[prompt.details.hopIndex] = next
            }
            let promptNumber = promptCountsByHop.load()[
                prompt.details.hopIndex
            ] ?? 0
            if isHostReview(prompt) {
                return "yes"
            }
            switch prompt.kind {
            case .hostKey:
                throw KwtSSHLeaseError.malformedEvent
            case .authentication:
                if promptNumber == 1 {
                    return "yes"
                }
                return "ghosthub-fixture-passphrase"
            }
        }
        let coldAcquisitionStarted = ContinuousClock.now
        let anchor = try await pool.acquire(route: route, prompt: promptHandler)
        let coldAcquisitionMilliseconds = milliseconds(
            coldAcquisitionStarted.duration(to: .now)
        )
        do {
            var warmCoordinationMilliseconds: [Double] = []
            for _ in 0 ..< 20 {
                let started = ContinuousClock.now
                let shared = try await pool.acquire(
                    route: route,
                    prompt: promptHandler
                )
                warmCoordinationMilliseconds.append(milliseconds(
                    started.duration(to: .now)
                ))
                try await shared.release()
            }
            #expect(rawAcquireCount.load() == 1)

            let output = AccountCommandRunner().runRemoteLoginShell(
                host: host,
                connectionArguments: anchor.arguments,
                command: expectedRemoteHostname == nil
                    ? "printf ghosthub-ssh-live"
                    : "hostname",
                timeout: 15
            )
            #expect(output.status == 0)
            #expect(
                output.stdout.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ) == (expectedRemoteHostname ?? "ghosthub-ssh-live")
            )
            if !answersFixturePrompts {
                let commandOutput = await KwtSSHCommandClient(
                    runner: { executable, arguments, timeout in
                        AccountCommandRunner.runProcess(
                            executable: executable,
                            arguments: arguments,
                            timeout: timeout,
                            environmentOverrides: environment
                        )
                    },
                    binaryPath: binary,
                    environment: environment
                ).run(
                    on: host,
                    command: expectedRemoteHostname == nil
                        ? "printf ghosthub-ssh-live"
                        : "hostname",
                    timeout: 15
                )
                #expect(commandOutput.status == 0)
                #expect(
                    commandOutput.stdout.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) == (expectedRemoteHostname ?? "ghosthub-ssh-live")
                )
            }
            if answersFixturePrompts, let expectedLogicalTargets {
                let received = prompts.load()
                for index in expectedLogicalTargets.indices {
                    let hopPrompts = received.filter {
                        $0.details.hopIndex == index
                    }
                    #expect(hopPrompts.count == 2)
                    #expect(hopPrompts.last?.kind == .authentication)
                    #expect(hopPrompts.last?.sensitive == true)
                }
                #expect(received.allSatisfy {
                    $0.details.hopCount == expectedLogicalTargets.count
                })
            }

            print(String(
                format: """
                kwt SSH \(label) timings (ms): direct ssh -G p95 %.2f; \
                cold kwt resolve %.2f; warm kwt resolve p95 %.2f; \
                cold lease %.2f; warm shared-token p95 %.2f
                """,
                percentile95(directResolutionMilliseconds),
                coldResolutionMilliseconds,
                percentile95(warmResolutionMilliseconds),
                coldAcquisitionMilliseconds,
                percentile95(warmCoordinationMilliseconds)
            ))
        } catch {
            try? await anchor.release()
            throw error
        }
        try await anchor.release()
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func percentile95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(
            (Double(sorted.count) * 0.95).rounded(.up) - 1
        ))]
    }

    private static func nonemptyEnvironmentValue(
        _ name: String,
        environment: [String: String]
    ) -> String? {
        guard let value = environment[name], !value.isEmpty else { return nil }
        return value
    }
}
