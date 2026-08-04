import Foundation
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("SSH authentication prompt broker")
struct SSHAuthenticationSessionTests {
    @Test("authentication launches through the account login shell")
    func launchesThroughAccountLoginShell() {
        let invocation = SSHAuthenticationSession.processInvocation(
            sshArguments: ["-N", "--", "operator@build.example.test"],
            accountShell: "/bin/fish"
        )

        #expect(invocation.executable.path == "/bin/fish")
        #expect(invocation.arguments.first == "-lc")
        #expect(invocation.arguments.count == 2)
        #expect(invocation.arguments[1].hasPrefix("exec /bin/sh -c "))
        #expect(invocation.arguments[1].contains("ghosthub-ssh-watchdog"))
        #expect(invocation.arguments[1].contains("operator@build.example.test"))
    }

    @Test("authentication removes inherited tmux launcher state")
    func sanitizesLauncherEnvironment() {
        let environment = SSHAuthenticationSession.processEnvironment(
            launcherEnvironment: [
                "PATH": "/usr/bin:/bin",
                "TMUX": "/tmp/tmux/default,1,0",
                "TMUX_PANE": "%3",
                "SSH_ASKPASS": "/untrusted/helper",
            ],
            askPassEnvironment: [
                "SSH_ASKPASS": "/private/ghosthub/askpass",
                "DISPLAY": "ghosthub",
            ]
        )

        #expect(environment["TMUX"] == nil)
        #expect(environment["TMUX_PANE"] == nil)
        #expect(environment["PATH"] == "/usr/bin:/bin")
        #expect(environment["SSH_ASKPASS"] == "/private/ghosthub/askpass")
    }

    @Test("SSH diagnostics drain continuously into a bounded tail")
    func drainsDiagnostics() async {
        let pipe = Pipe()
        let drain = SSHDiagnosticDrain.start(
            pipe: pipe,
            maximumBytes: 8
        )
        let writer = Task.detached {
            pipe.fileHandleForWriting.write(Data(repeating: 65, count: 128_000))
            pipe.fileHandleForWriting.write(Data("-newest".utf8))
            try? pipe.fileHandleForWriting.close()
        }

        await writer.value
        let diagnostic = await drain.finish()

        #expect(diagnostic == "A-newest")
    }

    @Test("cancelling diagnostics closes the nonblocking drain")
    func cancelsDiagnosticDrain() async {
        let pipe = Pipe()
        let drain = SSHDiagnosticDrain.start(pipe: pipe)

        drain.cancel()

        #expect(await drain.finish().isEmpty)
    }

    @Test("authentication rejects a changed cached SSH identity")
    func rejectsChangedCachedIdentity() {
        let target = SSHAuthenticationTarget(
            host: SSHHostInfo(
                user: "operator",
                hostname: "build.example.test",
                port: nil
            ),
            precedingProxyHops: []
        )

        let result = SSHAuthenticationPreparation.prepare(
            for: target,
            controlPath: "/tmp/ghosthub-test/control-reviewed",
            identityProvider: { target in
                SSHAuthenticationIdentity(
                    target: target,
                    controlPath: "/tmp/ghosthub-test/control-changed",
                    displayHost: target.host
                )
            },
            hostKeyArgumentsProvider: { _ in [] },
            proxyArgumentsProvider: { _ in [] }
        )

        guard case .configurationChanged = result else {
            Issue.record("Expected the stale identity to be rejected")
            return
        }
    }

    @Test("authentication binds the effective SSH endpoint to its prompt")
    func bindsEffectivePromptEndpoint() {
        let alias = SSHHostInfo(
            user: nil,
            hostname: "relay",
            port: nil
        )
        let resolved = SSHHostInfo(
            user: "admin",
            hostname: "jump.example.test",
            port: 2222
        )
        let result = SSHAuthenticationPreparation.prepare(
            for: SSHAuthenticationTarget(
                host: alias,
                precedingProxyHops: []
            ),
            controlPath: "/tmp/ghosthub-test/control-relay",
            identityProvider: { target in
                let displayHost = SSHConfigurationResolver.effectiveHost(
                    for: target.host,
                    configurationProvider: { configuredHost in
                        #expect(configuredHost == alias)
                        return EffectiveSSHConfiguration(
                            user: resolved.user,
                            strictHostKeyChecking: "yes",
                            proxyJump: nil,
                            proxyCommand: nil,
                            hostname: resolved.hostname,
                            port: resolved.port
                        )
                    }
                )
                return SSHAuthenticationIdentity(
                    target: target,
                    controlPath: "/tmp/ghosthub-test/control-relay",
                    displayHost: displayHost
                )
            },
            hostKeyArgumentsProvider: { _ in [] },
            proxyArgumentsProvider: { _ in [] }
        )

        guard case let .success(preparation) = result else {
            Issue.record("Expected authentication preparation to succeed")
            return
        }
        defer { preparation.temporaryState.remove() }
        #expect(preparation.displayHost == resolved)
        let presentation = SSHAuthenticationPresentation(
            target: preparation.displayHost,
            finalDestination: SSHHostInfo(
                user: "operator",
                hostname: "build.example.test",
                port: nil
            )
        )
        #expect(presentation.target == "admin@jump.example.test:2222")
    }

    @Test("authentication launches from its effective configuration snapshot")
    func launchesFromEffectiveConfigurationSnapshot() throws {
        let alias = SSHHostInfo(
            user: nil,
            hostname: "build-alias",
            port: nil
        )
        let target = SSHAuthenticationTarget(
            host: alias,
            precedingProxyHops: []
        )
        let configuration = SSHConfigurationResolver.parse("""
        user snapshot-user
        hostname snapshot.example.test
        port 2200
        stricthostkeychecking ask
        identityfile /snapshot/id_ed25519
        identityagent /snapshot/agent.sock
        userknownhostsfile /snapshot/known_hosts
        preferredauthentications publickey,password
        """)
        let snapshot = SSHConnectionPool.configurationSnapshot(
            for: target,
            configurationProvider: { _ in configuration }
        )
        let identity = try #require(SSHConnectionPool.authenticationIdentity(
            for: target,
            configurationSnapshot: snapshot
        ))

        let result = SSHAuthenticationPreparation.prepare(
            for: target,
            controlPath: identity.controlPath,
            configurationSnapshot: snapshot
        )

        guard case let .success(preparation) = result else {
            Issue.record("Expected authentication preparation to succeed")
            return
        }
        defer { preparation.temporaryState.remove() }
        #expect(preparation.displayHost.user == "snapshot-user")
        #expect(preparation.displayHost.hostname == "snapshot.example.test")
        #expect(preparation.displayHost.port == 2200)
        for option in [
            "HostName=snapshot.example.test",
            "User=snapshot-user",
            "identityfile=/snapshot/id_ed25519",
            "identityagent=/snapshot/agent.sock",
            "userknownhostsfile=/snapshot/known_hosts",
            "preferredauthentications=publickey,password",
        ] {
            #expect(preparation.configurationArguments.contains(option))
        }
        #expect(preparation.configurationArguments.contains("/dev/null"))
        #expect(!preparation.configurationArguments.contains {
            $0.hasPrefix("ProxyJump=")
        })

        let arguments = SSHConnectionPool.authenticationArguments(
            for: target,
            controlPath: preparation.controlPath,
            hostKeyArguments: preparation.hostKeyArguments,
            proxyArguments: preparation.proxyArguments,
            configurationArguments: preparation.configurationArguments
        )
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.suffix(2) == ["--", "build-alias"])
    }

    @Test("askpass exchanges a native response for the exact prompt")
    func exchangesPromptAndResponse() async throws {
        let state = try SSHAuthenticationTemporaryState.create()
        let output = Pipe()
        let process = Process()
        defer {
            if process.isRunning {
                process.terminate()
            }
            state.remove()
        }
        process.executableURL = state.helper
        process.arguments = ["Password for operator@build.example.test:"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GHOSTHUB_SSH_PROMPT_PATH": state.prompt.path,
            "GHOSTHUB_SSH_RESPONSE_FIFO": state.responseFIFO.path,
        ]) { _, new in new }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = ContinuousClock.now + .seconds(2)
        while !FileManager.default.fileExists(atPath: state.prompt.path),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let promptData = try Data(contentsOf: state.prompt)
        let prompt = try #require(SSHAuthenticationPrompt.parse(promptData))
        #expect(prompt.message == "Password for operator@build.example.test:")

        #expect(SSHAuthenticationSession.writeResponse(
            "synthetic-secret",
            toFIFO: state.responseFIFO
        ))
        let exitDeadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        try #require(!process.isRunning)
        #expect(process.terminationStatus == 0)
        #expect(
            output.fileHandleForReading.readDataToEndOfFile()
                == Data("synthetic-secret\n".utf8)
        )
    }

    @Test("the app-held watchdog pipe owns the child lifetime")
    func watchdogStopsChildAtEndOfAppSession() async throws {
        let watchdog = Pipe()
        let process = Process()
        defer {
            if process.isRunning {
                process.terminate()
            }
            try? watchdog.fileHandleForWriting.close()
        }
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", SSHAuthenticationSession.watchdogScript,
            "ghosthub-ssh-watchdog-test", "/bin/sleep", "30",
        ]
        process.standardInput = watchdog.fileHandleForReading
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try watchdog.fileHandleForReading.close()

        try watchdog.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!process.isRunning)
    }
}

@Suite("SSH authentication coordinator")
@MainActor
struct SSHAuthenticationCoordinatorTests {
    @Test("a session stops only after its final window releases it")
    func sharesSessionsAcrossWindowScopes() {
        let coordinator = SSHAuthenticationCoordinator()
        let host = SSHHostInfo(
            user: "operator",
            hostname: "unreachable.example.test",
            port: nil
        )
        let presentationID = UUID()
        let firstScope = UUID()
        let secondScope = UUID()
        let first = coordinator.session(
            scopeID: firstScope,
            presentationID: presentationID,
            host: host
        )
        let second = coordinator.session(
            scopeID: secondScope,
            presentationID: presentationID,
            host: host
        )

        #expect(first === second)
        coordinator.cancelAll(scopeID: firstScope)
        #expect(coordinator.session(
            scopeID: secondScope,
            presentationID: presentationID,
            host: host
        ) === first)

        coordinator.cancelAll(scopeID: secondScope)
        let connectedScope = UUID()
        let replacement = coordinator.session(
            scopeID: connectedScope,
            presentationID: presentationID,
            host: host
        )
        #expect(replacement !== first)
        replacement.markConnected()
        coordinator.cancelAll(scopeID: connectedScope)
        #expect(coordinator.session(
            scopeID: UUID(),
            presentationID: presentationID,
            host: host
        ) === replacement)
        coordinator.shutdown()
    }

    @Test("a cached control identity scopes shared authentication")
    func separatesCachedControlIdentities() {
        let coordinator = SSHAuthenticationCoordinator()
        let target = SSHAuthenticationTarget(
            host: SSHHostInfo(
                user: "operator",
                hostname: "unreachable.example.test",
                port: nil
            ),
            precedingProxyHops: []
        )
        let first = coordinator.session(
            scopeID: UUID(),
            presentationID: UUID(),
            target: target,
            controlPath: "/tmp/ghosthub-test/control-first"
        )
        let second = coordinator.session(
            scopeID: UUID(),
            presentationID: UUID(),
            target: target,
            controlPath: "/tmp/ghosthub-test/control-second"
        )

        #expect(first !== second)
        coordinator.shutdown()
    }

    @Test("invalidating a stale identity cancels its shared session")
    func invalidatesStaleIdentity() {
        let coordinator = SSHAuthenticationCoordinator()
        let scopeID = UUID()
        let presentationID = UUID()
        let target = SSHAuthenticationTarget(
            host: SSHHostInfo(
                user: "operator",
                hostname: "unreachable.example.test",
                port: nil
            ),
            precedingProxyHops: []
        )
        let controlPath = "/tmp/ghosthub-test/control-stale"
        let stale = coordinator.session(
            scopeID: scopeID,
            presentationID: presentationID,
            target: target,
            controlPath: controlPath
        )

        coordinator.invalidate(target: target, controlPath: controlPath)

        let replacement = coordinator.session(
            scopeID: scopeID,
            presentationID: presentationID,
            target: target,
            controlPath: controlPath
        )
        #expect(replacement !== stale)
        coordinator.shutdown()
    }
}

@Suite("Workspace SSH authentication readiness")
struct WorkspaceSSHAuthenticationReadinessTests {
    @Test("an authenticated proxy hop revalidates within the final route")
    func revalidatesIntermediateProxyHop() throws {
        let relay = SSHHostInfo(
            user: nil,
            hostname: "relay.example.test",
            port: nil
        )
        let finalHost = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: nil
        )
        let relayTarget = SSHAuthenticationTarget(
            host: relay,
            precedingProxyHops: []
        )
        let identity = WorkspaceSceneModel.currentSSHAuthenticationIdentity(
            for: relayTarget,
            finalHost: finalHost,
            configurationProvider: { host in
                if host == finalHost {
                    return EffectiveSSHConfiguration(
                        user: finalHost.user,
                        strictHostKeyChecking: "yes",
                        proxyJump: relay.hostname,
                        proxyCommand: nil
                    )
                }
                if host == relay {
                    return EffectiveSSHConfiguration(
                        user: "relay-user",
                        strictHostKeyChecking: "yes",
                        proxyJump: nil,
                        proxyCommand: nil,
                        hostname: "relay.internal.example.test",
                        port: 2200
                    )
                }
                return nil
            }
        )

        let resolved = try #require(identity)
        #expect(resolved.target == relayTarget)
        #expect(resolved.displayHost == SSHHostInfo(
            user: "relay-user",
            hostname: "relay.internal.example.test",
            port: 2200
        ))
    }
}
