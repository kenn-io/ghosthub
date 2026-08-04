import Foundation
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("SSH host trust")
struct SSHHostTrustManagerTests {
    private let prompt = """
    The authenticity of host 'build.example.test' can't be established.
    ED25519 key fingerprint is: SHA256:synthetic-fingerprint.
    Are you sure you want to continue connecting (yes/no/[fingerprint])?
    """

    @Test("an OpenSSH prompt becomes an exact-destination confirmation")
    func parsesConfirmation() throws {
        let confirmation = try SSHHostTrustManager.confirmation(
            destination: "dev@build.example.test",
            openSSHPrompt: prompt
        )

        #expect(confirmation.connectionDestination == "dev@build.example.test")
        #expect(confirmation.destination == "build.example.test")
        #expect(confirmation.algorithm == "ED25519")
        #expect(confirmation.fingerprint == "SHA256:synthetic-fingerprint")
        #expect(confirmation.openSSHPrompt == prompt)
    }

    @Test("approval is bound to the prompt and rechecks persistence")
    func acceptsOnlyThePresentedPrompt() throws {
        let calls = LockedValue(0)
        let manager = SSHHostTrustManager(
            askPassRunner: { _, _, _, _, approved, expected in
                calls.withLock { $0 += 1 }
                guard expected != nil else { return }
                FileManager.default.createFile(
                    atPath: approved.path,
                    contents: Data()
                )
            },
            strictHostKeyPolicyProvider: { _ in "ask" },
            routeProvider: { [$0] }
        )
        let confirmation = try SSHHostTrustManager.confirmation(
            destination: "dev@build.example.test",
            openSSHPrompt: prompt
        )

        let next = try manager.accept(
            confirmation,
            for: SSHHostInfo(
                user: "dev",
                hostname: "build.example.test",
                port: nil
            ),
            destination: "dev@build.example.test"
        )

        #expect(calls.load() == 2)
        #expect(next == nil)
    }

    @Test("a key changed before approval is rejected")
    func rejectsChangedPrompt() throws {
        let changedPrompt = prompt.replacingOccurrences(
            of: "synthetic-fingerprint",
            with: "different-synthetic-fingerprint"
        )
        let manager = SSHHostTrustManager(
            askPassRunner: { _, _, _, observed, _, expected in
                guard expected != nil else { return }
                try? Data(changedPrompt.utf8).write(to: observed)
            },
            strictHostKeyPolicyProvider: { _ in "ask" },
            routeProvider: { [$0] }
        )
        let confirmation = try SSHHostTrustManager.confirmation(
            destination: "dev@build.example.test",
            openSSHPrompt: prompt
        )

        #expect(throws: SSHHostTrustError.hostKeyChanged) {
            try manager.accept(
                confirmation,
                for: SSHHostInfo(
                    user: "dev",
                    hostname: "build.example.test",
                    port: nil
                ),
                destination: "dev@build.example.test"
            )
        }
    }

    @Test("a proxy using ask is reviewed even when the destination uses yes")
    func reviewsAskProxyBeforeStrictDestination() throws {
        let proxyPrompt = prompt.replacingOccurrences(
            of: "build.example.test",
            with: "jump.example.test"
        ).replacingOccurrences(
            of: "synthetic-fingerprint",
            with: "proxy-synthetic-fingerprint"
        )
        let destinationHost = SSHHostInfo(
            user: "dev",
            hostname: "build.example.test",
            port: nil
        )
        let proxyHost = SSHHostInfo(
            user: "relay",
            hostname: "jump.example.test",
            port: nil
        )
        let reviewedHosts = LockedValue(Set<String>())
        let calls = LockedValue([(host: String, proxies: [String])]())
        let manager = SSHHostTrustManager(
            askPassRunner: { host, proxies, _, observed, approved, expected in
                calls.withLock {
                    $0.append((host.hostname, proxies.map(\.hostname)))
                }
                if expected != nil, host == proxyHost {
                    FileManager.default.createFile(
                        atPath: approved.path,
                        contents: Data()
                    )
                    reviewedHosts.withLock { $0.insert(host.hostname) }
                } else if !reviewedHosts.load().contains(host.hostname) {
                    try? Data(proxyPrompt.utf8).write(to: observed)
                }
            },
            strictHostKeyPolicyProvider: {
                $0 == proxyHost ? "ask" : "yes"
            },
            routeProvider: { _ in [proxyHost, destinationHost] },
            authenticationProvider: { _ in true }
        )
        let proxyConfirmation = try #require(
            try manager.pendingConfirmation(
                for: destinationHost,
                destination: "dev@build.example.test"
            )
        )

        let next = try manager.accept(
            proxyConfirmation,
            for: destinationHost,
            destination: "dev@build.example.test"
        )

        #expect(proxyConfirmation.destination == "jump.example.test")
        #expect(next == nil)
        #expect(calls.load().allSatisfy { $0.host == "jump.example.test" })
        #expect(calls.load().allSatisfy { $0.proxies.isEmpty })
    }

    @Test("a proxy using accept-new is reviewed before an ask destination")
    func reviewsAcceptNewProxyBeforeAskDestination() throws {
        let proxyPrompt = prompt.replacingOccurrences(
            of: "build.example.test",
            with: "jump.example.test"
        )
        let destinationHost = SSHHostInfo(
            user: "dev",
            hostname: "build.example.test",
            port: nil
        )
        let proxyHost = SSHHostInfo(
            user: "relay",
            hostname: "jump.example.test",
            port: 2200
        )
        let reviewedHosts = LockedValue(Set<String>())
        let manager = SSHHostTrustManager(
            askPassRunner: { host, proxies, _, observed, approved, expected in
                if expected != nil {
                    FileManager.default.createFile(
                        atPath: approved.path,
                        contents: Data()
                    )
                    reviewedHosts.withLock { $0.insert(host.hostname) }
                    return
                }
                guard !reviewedHosts.load().contains(host.hostname) else {
                    return
                }
                let currentPrompt = host == proxyHost ? proxyPrompt : prompt
                try? Data(currentPrompt.utf8).write(to: observed)
                if host == destinationHost {
                    #expect(proxies == [proxyHost])
                }
            },
            strictHostKeyPolicyProvider: {
                $0 == proxyHost ? "accept-new" : "ask"
            },
            routeProvider: { _ in [proxyHost, destinationHost] },
            authenticationProvider: { _ in true }
        )
        let proxyConfirmation = try SSHHostTrustManager.confirmation(
            destination: "dev@build.example.test",
            openSSHPrompt: proxyPrompt
        )

        let next = try #require(try manager.accept(
            proxyConfirmation,
            for: destinationHost,
            destination: "dev@build.example.test"
        ))

        #expect(next.connectionDestination == "dev@build.example.test")
        #expect(next.destination == "build.example.test")
        #expect(next.fingerprint == "SHA256:synthetic-fingerprint")
    }

    @Test("a proxy authenticates before the next host key is reviewed")
    func requiresProxyAuthenticationBeforeDownstreamReview() throws {
        let destinationHost = SSHHostInfo(
            user: "dev",
            hostname: "build.example.test",
            port: nil
        )
        let proxyHost = SSHHostInfo(
            user: "relay",
            hostname: "jump.example.test",
            port: 2200
        )
        let proxyIsAuthenticated = LockedValue(false)
        let askPassCalls = LockedValue(0)
        let downstreamPrompt = prompt
        let manager = SSHHostTrustManager(
            askPassRunner: { host, proxies, _, observed, _, _ in
                askPassCalls.withLock { $0 += 1 }
                #expect(host == destinationHost)
                #expect(proxies == [proxyHost])
                try? Data(downstreamPrompt.utf8).write(to: observed)
            },
            strictHostKeyPolicyProvider: {
                $0 == proxyHost ? "yes" : "ask"
            },
            routeProvider: { _ in [proxyHost, destinationHost] },
            authenticationProvider: { _ in proxyIsAuthenticated.load() }
        )

        let first = try manager.pendingRequirement(
            for: destinationHost,
            destination: "dev@build.example.test"
        )
        #expect(first == .authentication(SSHAuthenticationTarget(
            host: proxyHost,
            precedingProxyHops: []
        )))
        #expect(askPassCalls.load() == 0)

        proxyIsAuthenticated.withLock { $0 = true }
        guard case let .confirmation(confirmation) =
            try manager.pendingRequirement(
                for: destinationHost,
                destination: "dev@build.example.test"
            )
        else {
            Issue.record("expected the downstream host-key confirmation")
            return
        }
        #expect(confirmation.destination == "build.example.test")
        #expect(askPassCalls.load() == 1)
    }

    @Test("non-review route hops authenticate in order")
    func authenticatesEveryNonReviewRouteHop() throws {
        let firstProxy = SSHHostInfo(
            user: "first",
            hostname: "first.example.test",
            port: nil
        )
        let secondProxy = SSHHostInfo(
            user: "second",
            hostname: "second.example.test",
            port: nil
        )
        let destinationHost = SSHHostInfo(
            user: "dev",
            hostname: "build.example.test",
            port: nil
        )
        let authenticated = LockedValue(Set<SSHAuthenticationTarget>())
        let manager = SSHHostTrustManager(
            askPassRunner: { _, _, _, _, _, _ in
                Issue.record("askpass must not run for non-review policies")
            },
            strictHostKeyPolicyProvider: {
                switch $0 {
                case firstProxy:
                    "yes"
                case secondProxy:
                    "off"
                default:
                    "no"
                }
            },
            routeProvider: { _ in
                [firstProxy, secondProxy, destinationHost]
            },
            authenticationProvider: { authenticated.load().contains($0) }
        )
        let firstTarget = SSHAuthenticationTarget(
            host: firstProxy,
            precedingProxyHops: []
        )
        let secondTarget = SSHAuthenticationTarget(
            host: secondProxy,
            precedingProxyHops: [firstProxy]
        )

        #expect(try manager.pendingRequirement(
            for: destinationHost,
            destination: "dev@build.example.test"
        ) == .authentication(firstTarget))

        authenticated.withLock { $0.insert(firstTarget) }
        #expect(try manager.pendingRequirement(
            for: destinationHost,
            destination: "dev@build.example.test"
        ) == .authentication(secondTarget))

        authenticated.withLock { $0.insert(secondTarget) }
        #expect(try manager.pendingRequirement(
            for: destinationHost,
            destination: "dev@build.example.test"
        ) == .none)
    }

    @Test(
        "explicit strict host-key policies are never overridden",
        arguments: ["yes", "no", "off", "true", "false"]
    )
    func respectsStrictHostKeyPolicy(policy: String) {
        let manager = SSHHostTrustManager(
            askPassRunner: { _, _, _, _, _, _ in
                Issue.record("askpass must not run for a strict policy")
            },
            strictHostKeyPolicyProvider: { _ in policy },
            routeProvider: { [$0] }
        )

        let confirmation = try? manager.pendingConfirmation(
            for: SSHHostInfo(
                user: "dev",
                hostname: "build.example.test",
                port: nil
            ),
            destination: "dev@build.example.test"
        )

        #expect(confirmation == nil)
    }

    @Test("opaque proxy commands fail closed")
    func rejectsProxyCommandRoutes() {
        let host = SSHHostInfo(
            user: "dev",
            hostname: "build.example.test",
            port: nil
        )

        #expect(throws: SSHHostTrustError.unsupportedProxyRoute) {
            try SSHHostTrustManager.route(
                for: host,
                configurationProvider: { _ in
                    EffectiveSSHConfiguration(
                        user: "dev",
                        strictHostKeyChecking: "ask",
                        proxyJump: nil,
                        proxyCommand: "ssh relay.example.test -W %h:%p"
                    )
                }
            )
        }
    }

    @Test("nested proxy routes fail closed")
    func rejectsNestedProxyRoutes() {
        let host = SSHHostInfo(
            user: "dev",
            hostname: "build.example.test",
            port: nil
        )

        #expect(throws: SSHHostTrustError.unsupportedProxyRoute) {
            try SSHHostTrustManager.route(
                for: host,
                configurationProvider: { target in
                    EffectiveSSHConfiguration(
                        user: target.user,
                        strictHostKeyChecking: "ask",
                        proxyJump: target == host
                            ? "relay.example.test"
                            : "edge.example.test",
                        proxyCommand: nil
                    )
                }
            )
        }
    }

    @Test("ProxyJump hosts are resolved in connection order")
    func resolvesProxyJumpRoute() throws {
        let host = SSHHostInfo(
            user: "dev",
            hostname: "build.example.test",
            port: nil
        )

        let route = try SSHHostTrustManager.route(
            for: host,
            configurationProvider: { target in
                EffectiveSSHConfiguration(
                    user: target.user,
                    strictHostKeyChecking: "ask",
                    proxyJump: target == host
                        ? "relay@[2001:db8::42]:2200,core.example.test"
                        : nil,
                    proxyCommand: nil
                )
            }
        )

        #expect(route[0].hostname == "2001:db8::42")
        #expect(route[0].port == 2200)
        #expect(
            SSHConfigurationResolver.proxyJumpDestination(for: route[0])
                == "relay@[2001:db8::42]:2200"
        )
        #expect(route.dropFirst().map(\.displayName) == [
            "core.example.test", "dev@build.example.test",
        ])
    }

    @Test("the shipped askpass helper approves only the expected key")
    func askPassScriptApprovesExpectedKey() throws {
        let expectedIdentity = "build.example.test\n"
            + "ED25519\nSHA256:synthetic-fingerprint\n"
        let changedAddressPrompt = prompt.replacingOccurrences(
            of: "build.example.test",
            with: "build.example.test (192.0.2.2)"
        )

        let approved = try runAskPass(
            prompt: changedAddressPrompt,
            expectedIdentity: expectedIdentity
        )
        #expect(approved.output == "yes\n")
        #expect(approved.markerCreated)
        #expect(approved.observedPrompt == nil)

        let changedKey = try runAskPass(
            prompt: prompt.replacingOccurrences(
                of: "synthetic-fingerprint",
                with: "different-synthetic-fingerprint"
            ),
            expectedIdentity: expectedIdentity
        )
        #expect(changedKey.output == "no\n")
        #expect(!changedKey.markerCreated)
        #expect(changedKey.observedPrompt != nil)

        let changedHost = try runAskPass(
            prompt: prompt.replacingOccurrences(
                of: "build.example.test",
                with: "other.example.test"
            ),
            expectedIdentity: expectedIdentity
        )
        #expect(changedHost.output == "no\n")
        #expect(!changedHost.markerCreated)

        let noExpectation = try runAskPass(
            prompt: prompt,
            expectedIdentity: nil
        )
        #expect(noExpectation.output == "no\n")
        #expect(!noExpectation.markerCreated)
    }

    @Test("the shipped askpass helper rejects authentication prompts")
    func askPassScriptRejectsAuthenticationPrompt() throws {
        let result = try runAskPass(
            prompt: "Password for relay@jump.example.test:",
            expectedIdentity: nil,
            expectedStatus: 1
        )

        #expect(result.status != 0)
        #expect(result.output.isEmpty)
        #expect(!result.markerCreated)
        #expect(result.observedPrompt == nil)
    }

    private func runAskPass(
        prompt: String,
        expectedIdentity: String?,
        expectedStatus: Int32 = 0
    ) throws -> (
        status: Int32,
        output: String,
        markerCreated: Bool,
        observedPrompt: String?
    ) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "ghosthub-askpass-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? fileManager.removeItem(at: directory) }
        let script = directory.appendingPathComponent("askpass")
        let observed = directory.appendingPathComponent("observed")
        let approved = directory.appendingPathComponent("approved")
        let expected = directory.appendingPathComponent("expected-key")
        try SSHHostTrustManager.askPassScript.write(
            to: script,
            atomically: true,
            encoding: .utf8
        )
        if let expectedIdentity {
            try expectedIdentity.write(
                to: expected,
                atomically: true,
                encoding: .utf8
            )
        }

        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, prompt]
        process.environment = [
            "GHOSTHUB_SSH_PROMPT_PATH": observed.path,
            "GHOSTHUB_SSH_APPROVED_PROMPT_PATH": approved.path,
            "GHOSTHUB_SSH_EXPECTED_KEY_PATH": expectedIdentity == nil
                ? "" : expected.path,
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == expectedStatus)
        return (
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            markerCreated: fileManager.fileExists(atPath: approved.path),
            observedPrompt: try? String(contentsOf: observed, encoding: .utf8)
        )
    }
}
