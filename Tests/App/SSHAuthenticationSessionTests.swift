import Foundation
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("SSH authentication prompt broker")
struct SSHAuthenticationSessionTests {
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
            controlPathProvider: { _ in
                "/tmp/ghosthub-test/control-changed"
            },
            hostKeyArgumentsProvider: { _ in [] },
            proxyArgumentsProvider: { _ in [] }
        )

        guard case .configurationChanged = result else {
            Issue.record("Expected the stale identity to be rejected")
            return
        }
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
}
