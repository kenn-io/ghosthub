import Testing
import GhosthubTerminal
@testable import GhosthubTerminalSupport

struct GhosttyBootstrapTests {
    @Test("ready status has the shared default values")
    func readyStatusHasExpectedDefaults() {
        let status = GhosttyBootstrapStatus.ready()
        expectSharedConstants(in: status)
        expectReadyState(for: status)
    }

    @Test("missing status has the shared default values")
    func missingStatusHasExpectedDefaults() {
        let status = GhosttyBootstrapStatus.missing()
        expectSharedConstants(in: status)
        expectMissingState(for: status)
    }

    @Test("status uses the shared support constants")
    func statusUsesSharedSupportConstants() {
        expectSharedConstants(in: GhosttyBootstrap.status())
    }

    @Test("status matches the compiled target")
    func statusMatchesCompiledTarget() {
        let status = GhosttyBootstrap.status()

        #if canImport(GhosttyKit)
        expectReadyState(for: status)
        #else
        expectMissingState(for: status)
        #endif
    }
}

// MARK: - Assertion Helpers

private func expectSharedConstants(
    in status: GhosttyBootstrapStatus,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        status.bootstrapCommand
            == GhosttyBootstrapSupport.bootstrapCommand,
        sourceLocation: sourceLocation
    )
    #expect(
        status.artifactRoot == GhosttyBootstrapSupport.artifactRoot,
        sourceLocation: sourceLocation
    )
}

private func expectReadyState(
    for status: GhosttyBootstrapStatus,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(status.isReady, sourceLocation: sourceLocation)
    #expect(status.message == nil, sourceLocation: sourceLocation)
}

private func expectMissingState(
    for status: GhosttyBootstrapStatus,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(!status.isReady, sourceLocation: sourceLocation)
    #expect(
        status.message
            == GhosttyBootstrapSupport.missingArtifactsMessage,
        sourceLocation: sourceLocation
    )
}
