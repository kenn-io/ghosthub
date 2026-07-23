import Testing
import GhosthubTerminal
@testable import GhosthubTerminalSupport

struct LibghosttyBootstrapTests {
    @Test("ready status has the shared default values")
    func readyStatusHasExpectedDefaults() {
        let status = LibghosttyBootstrapStatus.ready()
        expectSharedConstants(in: status)
        expectReadyState(for: status)
    }

    @Test("missing status has the shared default values")
    func missingStatusHasExpectedDefaults() {
        let status = LibghosttyBootstrapStatus.missing()
        expectSharedConstants(in: status)
        expectMissingState(for: status)
    }

    @Test("status uses the shared support constants")
    func statusUsesSharedSupportConstants() {
        expectSharedConstants(in: LibghosttyBootstrap.status())
    }

    @Test("status matches the compiled target")
    func statusMatchesCompiledTarget() {
        let status = LibghosttyBootstrap.status()

        #if canImport(GhosttyKit)
        expectReadyState(for: status)
        #else
        expectMissingState(for: status)
        #endif
    }
}

// MARK: - Assertion Helpers

private func expectSharedConstants(
    in status: LibghosttyBootstrapStatus,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        status.bootstrapCommand
            == LibghosttyBootstrapSupport.bootstrapCommand,
        sourceLocation: sourceLocation
    )
    #expect(
        status.artifactRoot == LibghosttyBootstrapSupport.artifactRoot,
        sourceLocation: sourceLocation
    )
}

private func expectReadyState(
    for status: LibghosttyBootstrapStatus,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(status.isReady, sourceLocation: sourceLocation)
    #expect(status.message == nil, sourceLocation: sourceLocation)
}

private func expectMissingState(
    for status: LibghosttyBootstrapStatus,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(!status.isReady, sourceLocation: sourceLocation)
    #expect(
        status.message
            == LibghosttyBootstrapSupport.missingArtifactsMessage,
        sourceLocation: sourceLocation
    )
}
