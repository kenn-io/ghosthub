import Foundation
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("SSH connection pool")
struct SSHConnectionPoolTests {
    @Test("authentication accepts a native secure response through OpenSSH")
    func authenticationUsesInteractiveOpenSSHMaster() {
        let host = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: 22
        )
        let arguments = SSHConnectionPool.authenticationArguments(
            for: host,
            controlPath: "/tmp/ghosthub-test/control-%C",
            hostKeyArguments: ["-o", "StrictHostKeyChecking=yes"],
            environment: [
                "GHOSTHUB_DEMO_SCRATCH": "/tmp/ghosthub-demo",
                "GHOSTHUB_DEMO_SSH_DIR": "/tmp/ghosthub-demo/ssh",
            ]
        )

        #expect(arguments.first == "-N")
        #expect(arguments.contains("BatchMode=no"))
        #expect(arguments.contains("ControlMaster=yes"))
        #expect(arguments.contains("ControlPersist=no"))
        #expect(arguments.contains("ForkAfterAuthentication=no"))
        #expect(arguments.contains("NumberOfPasswordPrompts=1"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("/tmp/ghosthub-demo/ssh/config"))
        #expect(arguments.contains(
            "UserKnownHostsFile=/tmp/ghosthub-demo/ssh/known_hosts"
        ))
        #expect(arguments.filter {
            $0.hasPrefix("ControlMaster=")
        } == ["ControlMaster=yes", "ControlMaster=no"])
        #expect(arguments.filter {
            $0.hasPrefix("ControlPath=")
        } == [
            "ControlPath=/tmp/ghosthub-test/control-%C",
            "ControlPath=none",
        ])
        #expect(arguments.suffix(4) == [
            "-p", "22", "--", "operator@build.example.test",
        ])
    }

    @Test("route authentication names the host controlling the prompt")
    func routeAuthenticationPresentationNamesControllingHost() {
        let presentation = SSHAuthenticationPresentation(
            target: SSHHostInfo(
                user: "relay",
                hostname: "jump.example.test",
                port: 2200
            ),
            finalDestination: SSHHostInfo(
                user: "operator",
                hostname: "build.example.test",
                port: nil
            )
        )

        #expect(
            presentation.heading
                == "Authenticate to relay@jump.example.test:2200 to continue"
                + " to operator@build.example.test"
        )
        #expect(
            presentation.credentialWarning
                == "The prompt below is controlled by"
                + " relay@jump.example.test:2200. Enter only credentials"
                + " for that host."
        )
    }

    @Test("connection checks preserve the explicit destination")
    func checkUsesSameControlIdentity() {
        #expect(SSHConnectionPool.connectionArguments(
            controlPath: nil
        ) == [
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
        ])
        #expect(SSHConnectionPool.connectionArguments(
            controlPath: "/tmp/ghosthub-test/control-%C"
        ) == [
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
            "-o", "ControlPath=/tmp/ghosthub-test/control-%C",
        ])

        let arguments = SSHConnectionPool.checkArguments(
            for: SSHHostInfo(
                user: "operator",
                hostname: "build.example.test",
                port: 2200
            ),
            controlPath: "/tmp/ghosthub-test/control-%C"
        )

        #expect(arguments == [
            "-O", "check",
            "-o", "BatchMode=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
            "-o", "ControlPath=/tmp/ghosthub-test/control-%C",
            "-p", "2200",
            "--", "operator@build.example.test",
        ])
    }

    @Test("control sockets are scoped to the resolved SSH route")
    func controlSocketUsesResolvedRoute() {
        let host = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: 22
        )
        let directName = SSHConnectionPool.controlName(
            for: host,
            configurationProvider: { _ in
                EffectiveSSHConfiguration(
                    user: "operator",
                    strictHostKeyChecking: "yes",
                    proxyJump: nil,
                    proxyCommand: nil,
                    hostname: "build.internal",
                    port: 22
                )
            }
        )
        let proxiedName = SSHConnectionPool.controlName(
            for: host,
            configurationProvider: { requestedHost in
                if requestedHost.hostname == "relay.example.test" {
                    return EffectiveSSHConfiguration(
                        user: "relay-user",
                        strictHostKeyChecking: "yes",
                        proxyJump: nil,
                        proxyCommand: nil,
                        hostname: "relay.internal",
                        port: 2200
                    )
                }
                return EffectiveSSHConfiguration(
                    user: "operator",
                    strictHostKeyChecking: "yes",
                    proxyJump: "relay.example.test",
                    proxyCommand: nil,
                    hostname: "build.internal",
                    port: 22
                )
            }
        )

        #expect(directName != proxiedName)
        #expect(proxiedName.hasPrefix("control-"))
        #expect(proxiedName.count <= 40)
    }

    @Test("authentication route and control path share one config snapshot")
    func authenticationIdentityUsesOneSnapshot() throws {
        let host = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: nil
        )
        let originalProxy = SSHHostInfo(
            user: nil,
            hostname: "original-jump.example.test",
            port: nil
        )
        let changedProxy = "changed-jump.example.test"
        let rootReads = LockedValue(0)
        let originalConfiguration = EffectiveSSHConfiguration(
            user: "operator",
            strictHostKeyChecking: "yes",
            proxyJump: originalProxy.hostname,
            proxyCommand: nil,
            hostname: "build.internal"
        )
        let changingConfiguration:
            SSHConfigurationResolver.ConfigurationProvider = {
                requestedHost in
                if requestedHost == host {
                    let read = rootReads.load()
                    rootReads.store(read + 1)
                    if read == 0 {
                        return originalConfiguration
                    }
                    return EffectiveSSHConfiguration(
                        user: "operator",
                        strictHostKeyChecking: "yes",
                        proxyJump: changedProxy,
                        proxyCommand: nil,
                        hostname: "build.internal"
                    )
                }
                return EffectiveSSHConfiguration(
                    user: "relay",
                    strictHostKeyChecking: "yes",
                    proxyJump: nil,
                    proxyCommand: nil
                )
            }
        let resolvedIdentity = SSHConnectionPool.authenticationIdentity(
            for: host,
            configurationProvider: changingConfiguration
        )
        let identity = try #require(resolvedIdentity)
        let expectedName = SSHConnectionPool.controlName(
            for: identity.target,
            configurationProvider: { requestedHost in
                if requestedHost == host {
                    return originalConfiguration
                }
                return EffectiveSSHConfiguration(
                    user: "relay",
                    strictHostKeyChecking: "yes",
                    proxyJump: nil,
                    proxyCommand: nil
                )
            }
        )

        #expect(identity.target.precedingProxyHops == [originalProxy])
        #expect(URL(fileURLWithPath: identity.controlPath).lastPathComponent == expectedName)
        #expect(rootReads.load() == 1)
    }

    @Test("control sockets are scoped to one app launch")
    func controlSocketUsesAppSession() {
        let host = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: nil
        )
        let configuration: SSHConfigurationResolver.ConfigurationProvider = {
            _ in
            EffectiveSSHConfiguration(
                user: "operator",
                strictHostKeyChecking: "yes",
                proxyJump: nil,
                proxyCommand: nil
            )
        }

        #expect(SSHConnectionPool.controlName(
            for: host,
            configurationProvider: configuration,
            sessionID: "first-launch"
        ) != SSHConnectionPool.controlName(
            for: host,
            configurationProvider: configuration,
            sessionID: "second-launch"
        ))
    }

    @Test("control cleanup removes dead sessions and preserves live sessions")
    func removesOnlyDeadControlSessions() throws {
        let stateHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateHome) }
        let directory = stateHome.appendingPathComponent(
            "ssh",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let stale = directory.appendingPathComponent(
            "session-101-stale",
            isDirectory: true
        )
        let live = directory.appendingPathComponent(
            "session-202-live",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stale,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: live,
            withIntermediateDirectories: false
        )
        let legacyControl = directory.appendingPathComponent("control-legacy")
        let unrelated = directory.appendingPathComponent("notes")
        _ = FileManager.default.createFile(
            atPath: stale.appendingPathComponent("control-old").path,
            contents: Data()
        )
        _ = FileManager.default.createFile(
            atPath: live.appendingPathComponent("control-active").path,
            contents: Data()
        )
        _ = FileManager.default.createFile(
            atPath: legacyControl.path,
            contents: Data()
        )
        _ = FileManager.default.createFile(
            atPath: unrelated.path,
            contents: Data()
        )

        SSHConnectionPool.removeStaleControlSockets(
            environment: ["GHOSTHUB_STATE_HOME": stateHome.path],
            processIsRunning: { $0 == 202 }
        )

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(FileManager.default.fileExists(atPath: legacyControl.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("route authentication reuses the preceding control master")
    func routeAuthenticationUsesPrecedingMaster() {
        let proxy = SSHHostInfo(
            user: "relay",
            hostname: "jump.example.test",
            port: 2200
        )
        let target = SSHAuthenticationTarget(
            host: SSHHostInfo(
                user: "operator",
                hostname: "build.example.test",
                port: nil
            ),
            precedingProxyHops: [proxy]
        )
        let arguments = SSHConnectionPool.proxyArguments(
            for: target,
            configurationProvider: { _ in
                EffectiveSSHConfiguration(
                    user: "operator",
                    strictHostKeyChecking: "yes",
                    proxyJump: nil,
                    proxyCommand: nil
                )
            }
        )

        #expect(arguments.contains("ProxyJump=none"))
        #expect(arguments.contains(where: {
            $0.hasPrefix("ProxyCommand=")
                && $0.contains("ControlPath=")
                && $0.contains("ControlMaster=no")
                && $0.contains("ControlPersist=no")
                && $0.contains("relay@jump.example.test")
        }))
    }

    @Test("authentication never strips an unresolved proxy route")
    func invalidProxyRouteFailsClosed() {
        let target = SSHAuthenticationTarget(
            host: SSHHostInfo(
                user: "operator",
                hostname: "build.example.test",
                port: nil
            ),
            precedingProxyHops: []
        )

        let arguments = SSHConnectionPool.proxyArguments(
            for: target,
            configurationProvider: { _ in
                EffectiveSSHConfiguration(
                    user: "operator",
                    strictHostKeyChecking: "yes",
                    proxyJump: "unresolved-route",
                    proxyCommand: nil
                )
            }
        )

        #expect(arguments.contains("ProxyJump=none"))
        #expect(arguments.contains("ProxyCommand=/usr/bin/false"))
        #expect(!arguments.contains("ProxyCommand=none"))
    }

    @Test("control sockets are scoped to every effective host-key alias")
    func controlSocketUsesHostKeyAliases() {
        let host = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: 22
        )
        let originalName = SSHConnectionPool.controlName(
            for: host,
            configurationProvider: { _ in
                EffectiveSSHConfiguration(
                    user: "operator",
                    strictHostKeyChecking: "yes",
                    proxyJump: nil,
                    proxyCommand: nil,
                    hostname: "build.internal",
                    port: 22,
                    hostKeyAlias: "original-key.example.test"
                )
            }
        )
        let changedName = SSHConnectionPool.controlName(
            for: host,
            configurationProvider: { _ in
                EffectiveSSHConfiguration(
                    user: "operator",
                    strictHostKeyChecking: "yes",
                    proxyJump: nil,
                    proxyCommand: nil,
                    hostname: "build.internal",
                    port: 22,
                    hostKeyAlias: "replacement-key.example.test"
                )
            }
        )
        let originalProxyName = SSHConnectionPool.controlName(
            for: host,
            configurationProvider: { requestedHost in
                if requestedHost.hostname == "relay.example.test" {
                    return EffectiveSSHConfiguration(
                        user: "relay-user",
                        strictHostKeyChecking: "yes",
                        proxyJump: nil,
                        proxyCommand: nil,
                        hostKeyAlias: "original-relay-key.example.test"
                    )
                }
                return EffectiveSSHConfiguration(
                    user: "operator",
                    strictHostKeyChecking: "yes",
                    proxyJump: "relay.example.test",
                    proxyCommand: nil
                )
            }
        )
        let changedProxyName = SSHConnectionPool.controlName(
            for: host,
            configurationProvider: { requestedHost in
                if requestedHost.hostname == "relay.example.test" {
                    return EffectiveSSHConfiguration(
                        user: "relay-user",
                        strictHostKeyChecking: "yes",
                        proxyJump: nil,
                        proxyCommand: nil,
                        hostKeyAlias: "replacement-relay-key.example.test"
                    )
                }
                return EffectiveSSHConfiguration(
                    user: "operator",
                    strictHostKeyChecking: "yes",
                    proxyJump: "relay.example.test",
                    proxyCommand: nil
                )
            }
        )

        #expect(originalName != changedName)
        #expect(originalProxyName != changedProxyName)
    }

    @Test("control sockets are scoped to every effective host-key policy")
    func controlSocketUsesHostKeyPolicies() {
        let host = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: nil
        )
        func name(
            destinationPolicy: String,
            proxyPolicy: String
        ) -> String {
            SSHConnectionPool.controlName(
                for: host,
                configurationProvider: { requestedHost in
                    if requestedHost.hostname == "relay.example.test" {
                        return EffectiveSSHConfiguration(
                            user: "relay-user",
                            strictHostKeyChecking: proxyPolicy,
                            proxyJump: nil,
                            proxyCommand: nil
                        )
                    }
                    return EffectiveSSHConfiguration(
                        user: "operator",
                        strictHostKeyChecking: destinationPolicy,
                        proxyJump: "relay.example.test",
                        proxyCommand: nil
                    )
                }
            )
        }

        #expect(
            name(destinationPolicy: "no", proxyPolicy: "yes")
                != name(destinationPolicy: "yes", proxyPolicy: "yes")
        )
        #expect(
            name(destinationPolicy: "yes", proxyPolicy: "no")
                != name(destinationPolicy: "yes", proxyPolicy: "yes")
        )
        #expect(
            name(destinationPolicy: "true", proxyPolicy: "yes")
                == name(destinationPolicy: "yes", proxyPolicy: "yes")
        )
    }

    @Test(
        "control sockets are scoped to resolved SSH security settings",
        arguments: [
            (
                "identityfile ~/.ssh/original_ed25519",
                "identityfile ~/.ssh/replacement_ed25519"
            ),
            (
                "userknownhostsfile ~/.ssh/known_hosts",
                "userknownhostsfile ~/.ssh/isolated_known_hosts"
            ),
        ]
    )
    func controlSocketUsesResolvedSecuritySettings(
        originalOption: String,
        changedOption: String
    ) {
        let host = SSHHostInfo(
            user: "operator",
            hostname: "build.example.test",
            port: nil
        )
        func name(option: String) -> String {
            let configuration = SSHConfigurationResolver.parse("""
            user operator
            hostname build.example.test
            port 22
            stricthostkeychecking true
            \(option)
            """)
            return SSHConnectionPool.controlName(
                for: host,
                configurationProvider: { _ in configuration },
                sessionID: "test-launch"
            )
        }

        #expect(name(option: originalOption) != name(option: changedOption))
    }
}
