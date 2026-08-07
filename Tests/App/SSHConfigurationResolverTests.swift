import Foundation
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
        hostkeyalias build-key.example.test
        identityfile ~/.ssh/id_ed25519
        identityfile ~/.ssh/id_rsa
        userknownhostsfile ~/.ssh/known_hosts
        """)

        #expect(configuration.user == "deploy")
        #expect(configuration.strictHostKeyChecking == "accept-new")
        #expect(configuration.proxyJump == "relay.example.test")
        #expect(configuration.proxyCommand == nil)
        #expect(configuration.hostname == "build.example.test")
        #expect(configuration.port == 2200)
        #expect(configuration.hostKeyAlias == "build-key.example.test")
        #expect(configuration.resolvedOptions.filter {
            $0.hasPrefix("identityfile=")
        } == [
            "identityfile=~/.ssh/id_ed25519",
            "identityfile=~/.ssh/id_rsa",
        ])
        #expect(configuration.resolvedOptions.contains(
            "userknownhostsfile=~/.ssh/known_hosts"
        ))
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

    @Test("SSH configuration excludes login-shell output")
    func extractsFramedConfiguration() throws {
        let output = """
        startup banner with spaces
        GHOSTHUB_SSH_CONFIG_START_nonce
        user deploy
        hostname build.example.test

        GHOSTHUB_SSH_CONFIG_END_nonce
        trailing shell output
        """

        let framed = try #require(
            SSHConfigurationResolver.framedConfigurationOutput(
                output,
                startMarker: "GHOSTHUB_SSH_CONFIG_START_nonce",
                endMarker: "GHOSTHUB_SSH_CONFIG_END_nonce"
            )
        )
        let configuration = SSHConfigurationResolver.parse(framed)

        #expect(configuration.user == "deploy")
        #expect(configuration.hostname == "build.example.test")
        #expect(!configuration.resolvedOptions.contains(
            "startup=banner with spaces"
        ))
        #expect(!configuration.resolvedOptions.contains(
            "trailing=shell output"
        ))
    }

    @Test(
        "noninteractive SSH cannot enroll keys for interactive policies",
        arguments: [nil, "ask", "accept-new", "unexpected"]
    )
    func locksInteractivePolicies(policy: String?) {
        #expect(
            SSHConfigurationResolver.noninteractiveHostKeyArguments(
                effectivePolicy: policy
            ) == [
                "-o", "StrictHostKeyChecking=yes",
                "-o", "UpdateHostKeys=no",
            ]
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
                            proxyCommand: nil,
                            resolvedOptions: [
                                "controlmaster=auto",
                                "controlpersist=600",
                                "proxyusefdpass=yes",
                            ]
                        )
                    case "core.example.test":
                        EffectiveSSHConfiguration(
                            user: nil,
                            strictHostKeyChecking: "accept-new",
                            proxyJump: nil,
                            proxyCommand: nil,
                            resolvedOptions: [
                                "controlmaster=auto",
                                "controlpersist=600",
                                "proxyusefdpass=yes",
                            ]
                        )
                    default:
                        nil
                    }
                }
            )

        #expect(arguments.count == 4)
        #expect(arguments[0] == "-o")
        #expect(arguments[1] == "ProxyUseFdpass=no")
        #expect(arguments[2] == "-o")
        #expect(arguments[3].hasPrefix("ProxyCommand="))
        let proxyCommand = String(
            arguments[3].dropFirst("ProxyCommand=".count)
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
        #expect(
            proxyCommand.components(
                separatedBy: "UpdateHostKeys=no"
            ).count == 3
        )
        for option in [
            "BatchMode=yes",
            "ControlMaster=no",
            "ControlPersist=no",
            "ControlPath=none",
            "ProxyUseFdpass=no",
            "ConnectTimeout=10",
            "ConnectionAttempts=1",
        ] {
            #expect(
                proxyCommand.components(separatedBy: option).count == 3
            )
        }
        #expect(!proxyCommand.contains("ControlMaster=auto"))
        #expect(!proxyCommand.contains("ControlPersist=600"))
        #expect(!proxyCommand.contains("ProxyUseFdpass=yes"))
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

        #expect(arguments[0 ... 3] == [
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UpdateHostKeys=no",
        ])
        #expect(arguments[4 ... 5] == ["-o", "ProxyUseFdpass=no"])
        #expect(arguments[6] == "-o")
        #expect(arguments[7].contains("BatchMode=no"))
        #expect(arguments[7].contains("StrictHostKeyChecking=yes"))
        #expect(arguments[7].contains("UpdateHostKeys=no"))
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

    @Test("authentication snapshots defer fd passing to generated proxies")
    func excludesProxyUseFdpassFromAuthenticationSnapshot() {
        let host = SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: nil
        )

        let arguments = SSHConfigurationResolver
            .snapshotAuthenticationArguments(
                for: host,
                configurationProvider: { _ in
                    EffectiveSSHConfiguration(
                        user: "deploy",
                        strictHostKeyChecking: "ask",
                        proxyJump: "relay.example.test",
                        proxyCommand: nil,
                        hostname: "build.internal",
                        resolvedOptions: [
                            "identityfile=~/.ssh/id_ed25519",
                            "proxyusefdpass=yes",
                        ]
                    )
                }
            )

        #expect(arguments.contains("identityfile=~/.ssh/id_ed25519"))
        #expect(!arguments.contains("proxyusefdpass=yes"))
    }

    @Test("connection snapshots preserve transport and key constraints")
    func preservesConnectionConstraints() {
        let host = SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: nil
        )
        let preserved = [
            "ciphers=aes256-gcm@openssh.com",
            "escapechar=none",
            "kexalgorithms=curve25519-sha256",
            "macs=hmac-sha2-512-etm@openssh.com",
            "requiredrsasize=4096",
            "sendenv=TMUX_TMPDIR",
        ]

        let arguments = SSHConfigurationResolver.snapshotConnectionArguments(
            for: host,
            configurationProvider: { _ in
                EffectiveSSHConfiguration(
                    user: "deploy",
                    strictHostKeyChecking: "ask",
                    proxyJump: nil,
                    proxyCommand: nil,
                    resolvedOptions: preserved + [
                        "setenv=GHOSTHUB_TMUX_PROFILE=fleet-secret",
                        "identityfile=/credentials/id_ed25519",
                    ]
                )
            }
        )

        for option in preserved {
            #expect(arguments.contains(option))
        }
        #expect(!arguments.contains(
            "setenv=GHOSTHUB_TMUX_PROFILE=fleet-secret"
        ))
        #expect(!arguments.contains("identityfile=/credentials/id_ed25519"))
    }

    @Test("connection snapshots keep SetEnv values in a private config file")
    func protectsSetEnvValuesFromProcessArguments() throws {
        let host = SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: nil
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let snapshot = SSHConfigurationResolver.connectionArgumentsSnapshot(
            for: host,
            configurationProvider: { _ in
                EffectiveSSHConfiguration(
                    user: "deploy",
                    strictHostKeyChecking: "yes",
                    proxyJump: nil,
                    proxyCommand: nil,
                    resolvedOptions: [
                        "sendenv=TMUX_TMPDIR",
                        "setenv=GHOSTHUB_TOKEN=fleet secret#value",
                    ]
                )
            },
            temporaryDirectory: temporaryDirectory
        )

        let configurationURL = try #require(snapshot.configurationURL)
        #expect(snapshot.arguments.contains(configurationURL.path))
        #expect(!snapshot.arguments.joined(separator: " ").contains(
            "fleet secret#value"
        ))
        let contents = try String(
            contentsOf: configurationURL,
            encoding: .utf8
        )
        #expect(contents.contains(
            "SetEnv \"GHOSTHUB_TOKEN=fleet secret#value\""
        ))
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: configurationURL.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: configurationURL.deletingLastPathComponent().path
        )
        let filePermissions = try #require(
            fileAttributes[.posixPermissions] as? NSNumber
        )
        let directoryPermissions = try #require(
            directoryAttributes[.posixPermissions] as? NSNumber
        )
        #expect(filePermissions.intValue & 0o777 == 0o600)
        #expect(directoryPermissions.intValue & 0o777 == 0o700)
    }

    @Test("connection snapshots retain authentication configuration")
    func preservesAuthenticationWithoutControlConnection() throws {
        let host = SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: nil
        )
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let snapshot = SSHConfigurationResolver.connectionArgumentsSnapshot(
            for: host,
            configurationProvider: { _ in
                EffectiveSSHConfiguration(
                    user: "deploy",
                    strictHostKeyChecking: "yes",
                    proxyJump: nil,
                    proxyCommand: nil,
                    resolvedOptions: [
                        "authenticationmethods=publickey,password",
                        "certificatefile=/credentials/deploy-cert.pub",
                        "enablesshkeysign=yes",
                        "identitiesonly=yes",
                        "identityagent=/run/user/501/ssh-agent.sock",
                        "identityfile=/credentials/deploy key",
                        "preferredauthentications=publickey,password",
                        "usekeychain=yes",
                    ]
                )
            },
            temporaryDirectory: temporaryDirectory
        )

        let configurationURL = try #require(snapshot.configurationURL)
        let contents = try String(
            contentsOf: configurationURL,
            encoding: .utf8
        )
        #expect(!contents.contains("AuthenticationMethods"))
        #expect(contents.contains(
            "CertificateFile \"/credentials/deploy-cert.pub\""
        ))
        #expect(contents.contains("EnableSSHKeysign \"yes\""))
        #expect(contents.contains("IdentitiesOnly \"yes\""))
        #expect(contents.contains(
            "IdentityAgent \"/run/user/501/ssh-agent.sock\""
        ))
        #expect(contents.contains(
            "IdentityFile \"/credentials/deploy key\""
        ))
        #expect(contents.contains(
            "PreferredAuthentications \"publickey,password\""
        ))
        #expect(contents.contains("UseKeychain \"yes\""))
        let parsed = TmuxBinaryResolver.runProcess(
            executable: "/usr/bin/ssh",
            arguments: ["-G"] + snapshot.arguments + ["--", "example.invalid"],
            timeout: 5
        )
        #expect(parsed.status == 0, Comment(rawValue: parsed.stderr))
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
            "-o", "UpdateHostKeys=no",
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
            "-o", "UpdateHostKeys=no",
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
            "-o", "UpdateHostKeys=no",
            "-o", "ProxyCommand=/usr/bin/false",
        ])
    }
}
