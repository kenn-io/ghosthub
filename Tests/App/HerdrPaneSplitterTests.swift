import GhosthubHerdr
import GhosthubTerminalSupport
import GhosthubTransport
import Synchronization
import Testing
@testable import GhosthubApp

@Suite("Herdr pane splitting")
struct HerdrPaneSplitterTests {
    @Test("commands scrub routing and split the frozen socket", arguments: [
        (TerminalPaneSplitShortcut.right, "right"),
        (TerminalPaneSplitShortcut.down, "down"),
    ])
    func command(
        shortcut: TerminalPaneSplitShortcut,
        direction: String
    ) {
        let command = HerdrPaneSplitter.command(
            herdrPath: "/opt/Herdr Tools/herdr",
            socketPath: "/srv/herdr/api/herdr.sock",
            shortcut: shortcut
        )

        #expect(command.hasPrefix(HerdrEnvironment.unsetCommand + "; "))
        #expect(command.contains(
            "export HERDR_SOCKET_PATH='/srv/herdr/api/herdr.sock'"
        ))
        #expect(command.hasSuffix(
            "exec '/opt/Herdr Tools/herdr' 'pane' 'split' "
                + "'--direction' '\(direction)' '--focus'"
        ))
        #expect(!command.contains("'--session'"))
        #expect(!command.contains("'--current'"))
        #expect(!command.contains("'session' 'list'"))
    }

    @Test("split uses the attachment's frozen remote route")
    func remoteRoute() async {
        struct Invocation: Sendable {
            var host: CommandHost
            var arguments: [String]
            var command: String
        }
        let invocation = Mutex<Invocation?>(nil)
        let host = CommandHost.ssh(.init(
            user: "dev",
            hostname: "build.example.test",
            port: 2222
        ))
        let splitter = HerdrPaneSplitter { host, arguments, command in
            invocation.withLock {
                $0 = Invocation(
                    host: host,
                    arguments: arguments,
                    command: command
                )
            }
            return (0, "")
        }

        let failure = await splitter.split(
            .right,
            target: HerdrPaneSplitTarget(
                host: host,
                herdrPath: "/usr/local/bin/herdr",
                sessionName: "api",
                socketPath: "/home/dev/.config/herdr/sessions/api/herdr.sock",
                sshConnectionArguments: [
                    "-o", "ControlPath=/tmp/frozen-control",
                    "-o", "StrictHostKeyChecking=yes",
                ]
            )
        )

        #expect(failure == nil)
        #expect(invocation.withLock { $0?.host } == host)
        #expect(invocation.withLock { $0?.arguments } == [
            "-o", "ControlPath=/tmp/frozen-control",
            "-o", "StrictHostKeyChecking=yes",
        ])
        #expect(invocation.withLock { $0?.command }.map {
            $0.contains("HERDR_SOCKET_PATH=")
        } == true)
    }

    @Test("nonzero status becomes a bounded user-facing failure")
    func failure() async {
        let splitter = HerdrPaneSplitter { _, _, _ in
            (
                9,
                String(repeating: " socket unavailable ", count: 100)
            )
        }
        let target = HerdrPaneSplitTarget(
            host: .local,
            herdrPath: "/usr/local/bin/herdr",
            sessionName: "api",
            socketPath: "/tmp/api/herdr.sock",
            sshConnectionArguments: []
        )

        let failure = await splitter.split(.down, target: target)

        #expect(failure?.status == 9)
        #expect(failure?.host == "localhost")
        #expect(failure?.sessionName == "api")
        #expect((failure?.diagnostic.count ?? 0) <= 400)
    }
}
