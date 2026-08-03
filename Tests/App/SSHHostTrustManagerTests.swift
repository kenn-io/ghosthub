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
            askPassRunner: { _, _, _, approved, expected in
                calls.withLock { $0 += 1 }
                guard expected != nil else { return }
                FileManager.default.createFile(
                    atPath: approved.path,
                    contents: Data()
                )
            },
            strictHostKeyPolicyProvider: { _ in "ask" }
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
            askPassRunner: { _, _, observed, _, expected in
                guard expected != nil else { return }
                try? Data(changedPrompt.utf8).write(to: observed)
            },
            strictHostKeyPolicyProvider: { _ in "ask" }
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

    @Test("sequential proxy host prompts are reviewed one at a time")
    func returnsNextProxyPrompt() throws {
        let proxyPrompt = prompt.replacingOccurrences(
            of: "build.example.test",
            with: "jump.example.test"
        ).replacingOccurrences(
            of: "synthetic-fingerprint",
            with: "proxy-synthetic-fingerprint"
        )
        let manager = SSHHostTrustManager(
            askPassRunner: {
                _, _, observed, approved, expected in
                if expected != nil {
                    FileManager.default.createFile(
                        atPath: approved.path,
                        contents: Data()
                    )
                } else {
                    try? Data(prompt.utf8).write(to: observed)
                }
            },
            strictHostKeyPolicyProvider: { _ in "accept-new" }
        )
        let proxyConfirmation = try SSHHostTrustManager.confirmation(
            destination: "dev@build.example.test",
            openSSHPrompt: proxyPrompt
        )

        let next = try #require(try manager.accept(
            proxyConfirmation,
            for: SSHHostInfo(
                user: "dev",
                hostname: "build.example.test",
                port: nil
            ),
            destination: "dev@build.example.test"
        ))

        #expect(next.connectionDestination == "dev@build.example.test")
        #expect(next.destination == "build.example.test")
        #expect(next.fingerprint == "SHA256:synthetic-fingerprint")
    }

    @Test("explicit strict host-key policies are never overridden")
    func respectsStrictHostKeyPolicy() {
        let manager = SSHHostTrustManager(
            askPassRunner: { _, _, _, _, _ in
                Issue.record("askpass must not run for a strict policy")
            },
            strictHostKeyPolicyProvider: { _ in "yes" }
        )

        #expect(throws: SSHHostTrustError
            .strictHostKeyPolicyUnsupported("yes")) {
            try manager.pendingConfirmation(
                for: SSHHostInfo(
                    user: "dev",
                    hostname: "build.example.test",
                    port: nil
                ),
                destination: "dev@build.example.test"
            )
        }
    }

    @Test("the shipped askpass helper approves only the expected key")
    func askPassScriptApprovesExpectedKey() throws {
        let expectedIdentity = "ED25519\nSHA256:synthetic-fingerprint\n"
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

        let noExpectation = try runAskPass(
            prompt: prompt,
            expectedIdentity: nil
        )
        #expect(noExpectation.output == "no\n")
        #expect(!noExpectation.markerCreated)
    }

    private func runAskPass(
        prompt: String,
        expectedIdentity: String?
    ) throws -> (
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
        #expect(process.terminationStatus == 0)
        return (
            output: String(decoding: data, as: UTF8.self),
            markerCreated: fileManager.fileExists(atPath: approved.path),
            observedPrompt: try? String(contentsOf: observed, encoding: .utf8)
        )
    }
}
