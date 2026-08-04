import Foundation
import Testing
@testable import GhosthubApp

@Suite("SSH authentication prompt broker")
struct SSHAuthenticationSessionTests {
    @Test("askpass exchanges a native response for the exact prompt")
    func exchangesPromptAndResponse() async throws {
        let state = try SSHAuthenticationTemporaryState.create()
        defer { state.remove() }
        let output = Pipe()
        let process = Process()
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
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(
            output.fileHandleForReading.readDataToEndOfFile()
                == Data("synthetic-secret\n".utf8)
        )
    }
}
