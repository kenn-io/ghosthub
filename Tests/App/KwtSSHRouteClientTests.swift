import Foundation
import GhosthubTestSupport
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("kwt SSH route resolution")
struct KwtSSHRouteClientTests {
    @Test("route resolution uses Ghosthub-owned kwt daemon state")
    func isolatesDaemonState() throws {
        let fixture = try TempDirectoryFixture()
        let kwtHome = StateHome.resolved()
            .appendingPathComponent("ssh", isDirectory: true)
            .appendingPathComponent("kwt", isDirectory: true)
        let helper = try fixture.createExecutable(
            name: "kwt",
            content: """
            #!/bin/sh
            [ "${KWT_HOME:-}" = \(shellQuotedCommandArgument(kwtHome.path)) ] || exit 90
            printf '%s\n' \(shellQuotedCommandArgument(Self.routeJSON))
            """
        )
        let client = KwtSSHRouteClient(binaryPath: helper.path)

        _ = try client.resolve(SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: 2200
        ))
    }

    @Test("bundled kwt resolves an ordered ProxyJump route")
    func resolvesOrderedRoute() throws {
        let invocation = LockedValue<(String, [String])?>(nil)
        let client = KwtSSHRouteClient(
            runner: { executable, arguments, _ in
                invocation.store((executable, arguments))
                return AccountCommandOutput(
                    status: 0,
                    stdout: Self.routeJSON,
                    stderr: ""
                )
            },
            binaryPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        )

        let snapshot = try client.resolve(SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: 2200
        ))

        #expect(invocation.load()?.0 ==
            "/Applications/Ghosthub.app/Contents/Helpers/kwt")
        #expect(invocation.load()?.1 == [
            "ssh", "resolve", "--json",
            "--user", "deploy",
            "--port", "2200",
            "build.example.test",
        ])
        #expect(snapshot.routeIdentity == "sha256:route-observation")
        #expect(snapshot.projectionPolicy == "kwt.openssh.projection.v1")
        #expect(snapshot.targets.map { $0.logicalTarget.hostname } == [
            "relay.example.test", "build.example.test",
        ])
        #expect(snapshot.targets[0].effectiveTarget.user == "jump")
        #expect(snapshot.targets[1].effectiveTarget.hostname ==
            "build.internal")
        #expect(snapshot.targets[1].projection.privateConfig == [
            "IdentityFile \"/Users/example/.ssh/deploy key\"",
        ])
    }

    @Test("non-app development execution resolves kwt through PATH")
    func developmentExecutionUsesPath() throws {
        let invocation = LockedValue<(String, [String])?>(nil)
        let client = KwtSSHRouteClient(
            runner: { executable, arguments, _ in
                invocation.store((executable, arguments))
                return AccountCommandOutput(
                    status: 0,
                    stdout: Self.routeJSON,
                    stderr: ""
                )
            },
            binaryPath: nil
        )

        _ = try client.resolve(SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: 2200
        ))

        #expect(invocation.load()?.0 == "/usr/bin/env")
        #expect(invocation.load()?.1.first == "kwt")
    }

    @Test("route snapshots must describe the requested target")
    func rejectsMismatchedTarget() {
        let client = KwtSSHRouteClient(
            runner: { _, _, _ in
                AccountCommandOutput(
                    status: 0,
                    stdout: Self.routeJSON,
                    stderr: ""
                )
            },
            binaryPath: "/kwt"
        )

        #expect(throws: KwtSSHRouteError.malformedOutput) {
            try client.resolve(SSHHostInfo(
                user: "deploy",
                hostname: "requested.example.test",
                port: 2200
            ))
        }
    }

    @Test("unknown projection policies fail closed")
    func rejectsUnknownProjectionPolicy() {
        let client = KwtSSHRouteClient(
            runner: { _, _, _ in
                AccountCommandOutput(
                    status: 0,
                    stdout: Self.routeJSON.replacingOccurrences(
                        of: "kwt.openssh.projection.v1",
                        with: "kwt.openssh.projection.v2"
                    ),
                    stderr: ""
                )
            },
            binaryPath: "/kwt"
        )

        #expect(throws: KwtSSHRouteError.unsupportedProjection(
            "kwt.openssh.projection.v2"
        )) {
            try client.resolve(SSHHostInfo(
                user: "deploy",
                hostname: "build.example.test",
                port: 2200
            ))
        }
    }

    private static let routeJSON = #"""
    {
      "logical_target": {
        "hostname": "build.example.test",
        "user": "deploy",
        "port": 2200
      },
      "targets": [
        {
          "logical_target": {"hostname":"relay.example.test"},
          "effective_target": {
            "hostname": "relay.example.test",
            "user": "jump",
            "port": 22
          },
          "display_target": "jump@relay.example.test",
          "strict_host_key_checking": "ask",
          "projection": {
            "arguments": [
              "-F", "/dev/null", "-o", "CanonicalizeHostname=no"
            ]
          }
        },
        {
          "logical_target": {
            "hostname": "build.example.test",
            "user": "deploy",
            "port": 2200
          },
          "effective_target": {
            "hostname": "build.internal",
            "user": "deploy",
            "port": 2200
          },
          "display_target": "deploy@build.internal:2200",
          "host_key_alias": "build-key.example.test",
          "strict_host_key_checking": "accept-new",
          "projection": {
            "arguments": [
              "-F", "/dev/null", "-o", "CanonicalizeHostname=no",
              "-o", "HostName=build.internal", "-p", "2200"
            ],
            "private_config": [
              "IdentityFile \"/Users/example/.ssh/deploy key\""
            ]
          }
        }
      ],
      "route_identity": "sha256:route-observation",
      "projection_policy": "kwt.openssh.projection.v1",
      "observed_at": "2026-08-13T19:00:00.123456Z"
    }
    """#
}
