import Testing
@testable import GhosthubApp

struct SSHConfigurationResolverTests {
    @Test("effective SSH configuration parses policy and user")
    func parsesConfiguration() {
        let configuration = SSHConfigurationResolver.parse("""
        host build.example.test
        user deploy
        stricthostkeychecking accept-new
        hostname build.example.test
        """)

        #expect(configuration.user == "deploy")
        #expect(configuration.strictHostKeyChecking == "accept-new")
    }
}
