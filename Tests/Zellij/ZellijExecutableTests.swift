import Testing
@testable import GhosthubZellij

@Suite("Zellij executable discovery")
struct ZellijExecutableTests {
    @Test("successful output without the marker is rejected")
    func missingMarker() {
        #expect(
            ZellijExecutable.parse(
                status: 0,
                stdout: "/usr/bin/zellij\n",
                stderr: ""
            ) == .failure(.missingMarker)
        )
    }
}
