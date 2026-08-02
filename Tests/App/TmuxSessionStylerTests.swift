import Foundation
import GhosthubTmux
import GhosthubUI
import Testing
@testable import GhosthubApp

private let testTmuxIdentity = TmuxSessionIdentity(
    serverPID: "31415",
    sessionID: "$42",
    createdAt: "1785182057"
)

@Suite("tmux session styling")
struct TmuxSessionStylerTests {
    @Test("styling routes the exact active session through its POSIX host")
    func routesExactSession() async throws {
        let calls = LockedValue<[(TmuxHost, String)]>([])
        let styler = TmuxSessionStyler(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { host, command in
                calls.withLock { $0.append((host, command)) }
                return (0, "")
            }
        )
        let host = TmuxHost.ssh(SSHHostInfo(
            user: "wesm",
            hostname: "builder",
            port: 2222
        ))
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "review's session",
            socketName: "protected"
        )

        try await styler.apply(
            TmuxPresentationStyle(
                foreground: "#DDEEFF",
                background: "#101820"
            ),
            to: selection,
            expectedIdentity: testTmuxIdentity,
            on: host
        )

        let recorded = calls.load()
        let call = try #require(recorded.count == 1 ? recorded[0] : nil)
        #expect(call.0 == host)
        #expect(call.1.contains("'-L' 'protected'"))
        #expect(call.1.contains("'=review'\\''s session:'"))
    }

    @Test("styling failure preserves host, session, and status")
    func commandFailure() async {
        let host = TmuxHost.ssh(SSHHostInfo(
            user: "wesm",
            hostname: "builder",
            port: 2222
        ))
        let styler = TmuxSessionStyler(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in (42, "") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "review"
        )

        await #expect {
            try await styler.apply(
                TmuxPresentationStyle(
                    foreground: "#DDEEFF",
                    background: "#101820"
                ),
                to: selection,
                expectedIdentity: testTmuxIdentity,
                on: host
            )
        } throws: { error in
            error as? TmuxSessionStyleError == .commandFailed(
                host: "wesm@builder:2222",
                session: "review",
                status: 42
            )
        }
    }

    @Test("identity mismatch preserves the replacement session")
    func identityMismatch() async {
        let styler = TmuxSessionStyler(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in
                (
                    0,
                    TmuxPresentationCommand.identityMismatchMarker + "\n"
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "review"
        )

        await #expect {
            try await styler.apply(
                TmuxPresentationStyle(
                    foreground: "#DDEEFF",
                    background: "#101820"
                ),
                to: selection,
                expectedIdentity: testTmuxIdentity,
                on: .local
            )
        } throws: { error in
            error as? TmuxSessionStyleError == .sessionChanged(
                host: "localhost",
                session: "review"
            )
        }
    }

    @Test("native Windows hosts reject styling before resolving tmux")
    func rejectsWindowsHost() async {
        let resolverCalls = LockedValue(0)
        let runnerCalls = LockedValue(0)
        let host = TmuxHost.ssh(SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: nil,
            platform: .windows
        ))
        let styler = TmuxSessionStyler(
            pathResolver: { _ in
                resolverCalls.withLock { $0 += 1 }
                return .success("tmux.exe")
            },
            runner: { _, _ in
                runnerCalls.withLock { $0 += 1 }
                return (0, "")
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "review"
        )

        await #expect {
            try await styler.apply(
                TmuxPresentationStyle(
                    foreground: "#DDEEFF",
                    background: "#101820"
                ),
                to: selection,
                expectedIdentity: testTmuxIdentity,
                on: host
            )
        } throws: { error in
            error as? TmuxSessionStyleError == .unsupportedHost(
                host: "wesm@arm-builder",
                session: "review"
            )
        }
        #expect(resolverCalls.load() == 0)
        #expect(runnerCalls.load() == 0)
    }

    @Test("styling updates a real local tmux session")
    func stylesRealLocalSession() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else {
            return
        }
        let socketName = "ghosthub-style-\(UUID().uuidString.lowercased())"
        let sessionName = "review"
        defer {
            _ = TmuxBinaryResolver.runProcess(
                executable: tmuxPath,
                arguments: ["-L", socketName, "kill-server"],
                timeout: 5
            )
        }
        let created = TmuxBinaryResolver.runProcess(
            executable: tmuxPath,
            arguments: [
                "-f", "/dev/null", "-L", socketName,
                "new-session", "-d", "-s", sessionName,
            ],
            timeout: 5
        )
        #expect(created.status == 0)

        let identity = try await TmuxSessionKiller(
            pathResolver: { _ in .success(tmuxPath) }
        ).sessionIdentity(
            WorkspaceTmuxSessionSelection(
                hostID: UUID(),
                name: sessionName,
                socketName: socketName
            ),
            on: .local
        )
        try await TmuxSessionStyler(
            pathResolver: { _ in .success(tmuxPath) }
        ).apply(
            TmuxPresentationStyle(
                foreground: "#DDEEFF",
                background: "#101820"
            ),
            to: WorkspaceTmuxSessionSelection(
                hostID: UUID(),
                name: sessionName,
                socketName: socketName
            ),
            expectedIdentity: identity,
            on: .local
        )

        let statusStyle = TmuxBinaryResolver.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "show-options", "-v", "-t",
                "=\(sessionName):", "status-style",
            ],
            timeout: 5
        )
        let windowStyle = TmuxBinaryResolver.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "show-options", "-v", "-w", "-t",
                "=\(sessionName):", "window-style",
            ],
            timeout: 5
        )
        #expect(statusStyle.status == 0)
        #expect(statusStyle.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "reverse")
        #expect(windowStyle.status == 0)
        #expect(windowStyle.stdout.contains("fg=#DDEEFF,bg=#101820"))
    }
}
