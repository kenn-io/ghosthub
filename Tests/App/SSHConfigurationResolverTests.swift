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

    @Test(
        "noninteractive SSH cannot enroll keys for interactive policies",
        arguments: [nil, "ask", "accept-new", "unexpected"]
    )
    func locksInteractivePolicies(policy: String?) {
        #expect(
            SSHConfigurationResolver.noninteractiveHostKeyArguments(
                effectivePolicy: policy
            ) == ["-o", "StrictHostKeyChecking=yes"]
        )
    }

    @Test(
        "explicit noninteractive SSH policies remain user-owned",
        arguments: ["yes", "no", "off"]
    )
    func preservesExplicitPolicies(policy: String) {
        #expect(
            SSHConfigurationResolver.noninteractiveHostKeyArguments(
                effectivePolicy: policy
            ).isEmpty
        )
    }
}
