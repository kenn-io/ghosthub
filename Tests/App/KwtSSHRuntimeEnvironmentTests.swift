import Foundation
import Testing
@testable import GhosthubApp

@Suite("kwt SSH runtime environment")
struct KwtSSHRuntimeEnvironmentTests {
    @Test("SSH kwt processes drop launcher terminal state and pin KWT_HOME")
    func sanitizesLauncherEnvironment() {
        let resolved = KwtSSHRuntimeEnvironment.resolved(environment: [
            "PATH": "/usr/bin",
            "TMUX": "/tmp/tmux-501/default,123,0",
            "TMUX_PANE": "%1",
        ])

        #expect(resolved["PATH"] == "/usr/bin")
        #expect(resolved["TMUX"] == nil)
        #expect(resolved["TMUX_PANE"] == nil)
        #expect(resolved["KWT_HOME"]?.hasSuffix("/ssh/kwt") == true)
    }
}
