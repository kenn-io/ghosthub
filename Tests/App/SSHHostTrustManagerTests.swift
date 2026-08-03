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
        let manager = SSHHostTrustManager { _, _, _, approved, expected in
            calls.withLock { $0 += 1 }
            guard expected != nil else { return }
            FileManager.default.createFile(
                atPath: approved.path,
                contents: Data()
            )
        }
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
        let manager = SSHHostTrustManager { _, _, observed, _, expected in
            guard expected != nil else { return }
            try? Data(changedPrompt.utf8).write(to: observed)
        }
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
        let manager = SSHHostTrustManager {
            _, _, observed, approved, expected in
            if expected != nil {
                FileManager.default.createFile(
                    atPath: approved.path,
                    contents: Data()
                )
            } else {
                try? Data(prompt.utf8).write(to: observed)
            }
        }
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
}
