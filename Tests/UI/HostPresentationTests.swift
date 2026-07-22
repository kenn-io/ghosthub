import Foundation
import Testing
@testable import GhosthubUI
@testable import GhosthubWorkspace

struct HostPresentationTests {
    @Test("command palette host commands surface remote state and identity")
    func commandPaletteHostSubtitleUsesRemoteMetadata() throws {
        let hostCommand = try makeHostCommand(
            for: .fixture(
                name: "Build Box",
                kind: .remote,
                platform: .linux,
                sshDestination: "rpi5-ssd",
                preferredTransport: .mosh,
                lastKnownReachable: false,
                lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
                remoteHostname: "rpi5-ssd.tail-scale.ts.net",
                version: "0.1.0"
            )
        )

        #expect(hostCommand.subtitle == "rpi5-ssd · Linux")
        #expect(hostCommand.keywords.contains("rpi5-ssd"))
        #expect(hostCommand.keywords.contains("offline"))
    }

    @Test("command palette host commands surface degraded diagnostics")
    func commandPaletteHostSubtitleUsesDiagnostics() throws {
        let hostCommand = try makeHostCommand(
            for: .fixture(
                name: "Office Studio",
                kind: .remote,
                platform: .macOS,
                sshDestination: "ghosthub-mac-e2e",
                lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
                version: "0.1.0",
                remoteCapabilities: RemoteHostCapabilities(
                    commands: RemoteHostCommandCapabilities(
                        worktreeCreate: true,
                        worktreeImportPullRequest: false,
                        worktreeDelete: true,
                        sessionEnsure: true,
                        sessionKill: true
                    ),
                    dependencies: RemoteHostDependencyCapabilities(
                        git: true, gh: false, tmux: true
                    ),
                    features: RemoteHostFeatureCapabilities(
                        resourceMetrics: true,
                        setupHook: true,
                        teardownHook: true,
                        moshAttach: false
                    )
                ),
                remoteDiagnostics: [
                    RemoteHostDiagnostic(
                        code: .missingGh,
                        severity: .warning,
                        summary: "Missing gh",
                        recoverySuggestion: "Install GitHub CLI (`gh`) on the remote host to import pull requests."
                    ),
                ]
            )
        )

        #expect(hostCommand
            .subtitle == "ghosthub-mac-e2e · macOS")
        #expect(hostCommand.keywords
            .contains("install github cli (`gh`) on the remote host to import pull requests."))
    }
}
