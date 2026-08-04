import Foundation
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("SSH authentication prompt broker")
struct SSHAuthenticationSessionTests {
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
        let replacement = coordinator.session(
            scopeID: UUID(),
            presentationID: presentationID,
            host: host
        )
        #expect(replacement !== first)
        coordinator.shutdown()
    }
}
