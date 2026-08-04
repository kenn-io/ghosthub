import GhosthubTmux
import Testing
@testable import GhosthubApp

struct SSHConfigurationResolverTests {
    @Test("effective SSH configuration parses policy and user")
    func parsesConfiguration() {
        let configuration = SSHConfigurationResolver.parse("""
        host build.example.test
        user deploy
        stricthostkeychecking accept-new
        proxyjump relay.example.test
        proxycommand none
        hostname build.example.test
        port 2200
        """)

        #expect(configuration.user == "deploy")
        #expect(configuration.strictHostKeyChecking == "accept-new")
        #expect(configuration.proxyJump == "relay.example.test")
        #expect(configuration.proxyCommand == nil)
        #expect(configuration.hostname == "build.example.test")
        #expect(configuration.port == 2200)
    }

    @Test(
        "effective SSH configuration normalizes canonical Boolean policies",
        arguments: [("true", "yes"), ("false", "no")]
    )
    func normalizesCanonicalPolicies(
        canonical: String,
        normalized: String
    ) {
        let configuration = SSHConfigurationResolver.parse("""
        user deploy
        stricthostkeychecking \(canonical)
        hostname build.example.test
        """)

        #expect(configuration.strictHostKeyChecking == normalized)
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
        arguments: ["yes", "no", "off", "true", "false"]
    )
    func preservesExplicitPolicies(policy: String) {
        #expect(
            SSHConfigurationResolver.noninteractiveHostKeyArguments(
                effectivePolicy: policy
            ).isEmpty
        )
    }

    @Test("noninteractive ProxyJump hardens each interactive hop")
    func hardensInteractiveProxyJumpHosts() {
        let destination = SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: nil
        )
        let arguments = SSHConfigurationResolver
            .noninteractiveHostKeyArguments(
                for: destination,
                configurationProvider: { host in
                    switch host.hostname {
                    case "build.example.test":
                        EffectiveSSHConfiguration(
                            user: "deploy",
                            strictHostKeyChecking: "true",
                            proxyJump:
                            "relay@[2001:db8::42]:2200,core.example.test",
                            proxyCommand: nil
                        )
                    case "2001:db8::42":
                        EffectiveSSHConfiguration(
                            user: "relay",
                            strictHostKeyChecking: "ask",
                            proxyJump: nil,
                            proxyCommand: nil
                        )
                    case "core.example.test":
                        EffectiveSSHConfiguration(
                            user: nil,
                            strictHostKeyChecking: "accept-new",
                            proxyJump: nil,
                            proxyCommand: nil
                        )
                    default:
                        nil
                    }
                }
            )

        #expect(arguments.count == 2)
        #expect(arguments[0] == "-o")
        #expect(arguments[1].hasPrefix("ProxyCommand="))
        let proxyCommand = String(
            arguments[1].dropFirst("ProxyCommand=".count)
        )
        #expect(SSHConfigurationResolver.proxyCommandHopArguments(
            for: SSHHostInfo(
                user: "relay",
                hostname: "2001:db8::42",
                port: 2200
            )
        ) == [
            "-p", "2200", "-W", "[%h]:%p", "relay@2001:db8::42",
        ])
        #expect(proxyCommand.contains("core.example.test"))
        #expect(proxyCommand.contains("StrictHostKeyChecking=yes"))
        #expect(
            proxyCommand.components(
                separatedBy: "StrictHostKeyChecking=yes"
            ).count == 3
        )
        for option in [
            "BatchMode=yes",
            "ConnectTimeout=10",
            "ConnectionAttempts=1",
        ] {
            #expect(
                proxyCommand.components(separatedBy: option).count == 3
            )
        }
        #expect(proxyCommand.contains("[%%h]:%%p"))
        #expect(proxyCommand.contains("[%h]:%p"))
    }

    @Test("interactive authentication permits prompts on trusted proxy hops")
    func interactiveAuthenticationPermitsProxyPrompts() {
        let destination = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: nil
        )
        let arguments = SSHConfigurationResolver.interactiveHostKeyArguments(
            for: destination,
            configurationProvider: { host in
                EffectiveSSHConfiguration(
                    user: host.user,
                    strictHostKeyChecking: "ask",
                    proxyJump: host == destination
                        ? "relay.example.test"
                        : nil,
                    proxyCommand: nil
                )
            }
        )

        #expect(arguments[0 ... 1] == [
            "-o", "StrictHostKeyChecking=yes",
        ])
        #expect(arguments[2] == "-o")
        #expect(arguments[3].contains("BatchMode=no"))
        #expect(arguments[3].contains("StrictHostKeyChecking=yes"))
    }

    @Test("malformed ProxyJump routes fail closed")
    func blocksMalformedProxyJumpRoutes() {
        let destination = SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: nil
        )

        let arguments = SSHConfigurationResolver
            .noninteractiveHostKeyArguments(
                for: destination,
                configurationProvider: { _ in
                    EffectiveSSHConfiguration(
                        user: "deploy",
                        strictHostKeyChecking: "true",
                        proxyJump: "relay.example.test,,core.example.test",
                        proxyCommand: nil
                    )
                }
            )

        #expect(arguments == ["-o", "ProxyCommand=/usr/bin/false"])
    }

    @Test("explicit default ProxyJump ports remain explicit")
    func preservesExplicitDefaultProxyPort() {
        let host = SSHHostInfo(
            user: "relay",
            hostname: "relay.example.test",
            port: 22
        )

        #expect(
            SSHConfigurationResolver.proxyJumpDestination(for: host)
                == "relay@relay.example.test:22"
        )
        #expect(SSHConfigurationResolver.proxyCommandHopArguments(
            for: host
        ) == [
            "-p", "22", "-W", "[%h]:%p", "relay@relay.example.test",
        ])
    }

    @Test("opaque proxy commands fail routine SSH operations closed")
    func blocksOpaqueProxyCommands() {
        let destination = SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: nil
        )

        let arguments = SSHConfigurationResolver
            .noninteractiveHostKeyArguments(
                for: destination,
                configurationProvider: { _ in
                    EffectiveSSHConfiguration(
                        user: "deploy",
                        strictHostKeyChecking: "ask",
                        proxyJump: nil,
                        proxyCommand: "ssh relay.example.test -W %h:%p"
                    )
                }
            )

        #expect(arguments == [
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ProxyCommand=/usr/bin/false",
        ])
    }

    @Test("nested proxy routes fail routine SSH operations closed")
    func blocksNestedProxyRoutes() {
        let destination = SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: nil
        )

        let arguments = SSHConfigurationResolver
            .noninteractiveHostKeyArguments(
                for: destination,
                configurationProvider: { host in
                    EffectiveSSHConfiguration(
                        user: host.user,
                        strictHostKeyChecking: "ask",
                        proxyJump: host == destination
                            ? "relay.example.test"
                            : "edge.example.test",
                        proxyCommand: nil
                    )
                }
            )

        #expect(arguments == [
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ProxyCommand=/usr/bin/false",
        ])
    }

    @Test("unresolved SSH configuration fails routine operations closed")
    func blocksUnresolvedConfiguration() {
        let arguments = SSHConfigurationResolver
            .noninteractiveHostKeyArguments(
                for: SSHHostInfo(
                    user: "deploy",
                    hostname: "build.example.test",
                    port: nil
                ),
                configurationProvider: { _ in nil }
            )

        #expect(arguments == [
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ProxyCommand=/usr/bin/false",
        ])
    }
}
