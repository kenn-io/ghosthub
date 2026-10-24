import GhosthubTransport
import Foundation
import GhosthubTestSupport
import GhosthubTmux
import GhosthubUI
import Testing
@testable import GhosthubApp

@Suite("tmux session rename")
struct TmuxSessionRenamerTests {
    @Test("Windows hosts are refused without running tmux")
    func windowsHostIsUnsupported() async {
        let commands = LockedValue<[String]>([])
        let renamer = TmuxSessionRenamer(
            pathResolver: { _ in .success("tmux") },
            runner: { _, command in
                commands.withLock { $0.append(command) }
                return (0, "")
            }
        )
        let host = SSHHostInfo(
            user: nil,
            hostname: "windows.example.test",
            port: nil,
            platform: .windows
        )

        await #expect {
            try await renamer.rename(
                WorkspaceTmuxSessionSelection(hostID: UUID(), name: "work"),
                to: "renamed",
                expectedIdentity: TmuxSessionIdentity(
                    serverPID: "1",
                    sessionID: "$1",
                    createdAt: "1"
                ),
                on: .ssh(host)
            )
        } throws: { error in
            error as? TmuxSessionRenameError == .unsupportedHost(
                host: host.displayName,
                session: "work"
            )
        }
        #expect(commands.load().isEmpty)
    }

    @Test("matching identity is renamed; replacements and duplicates are refused")
    func realTmuxRenameBoundary() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else {
            return
        }
        let server = try TestTmuxServer(
            tmuxPath: tmuxPath,
            socket: .runOwned(purpose: "rename")
        )
        defer { server.stop() }
        let socketName = server.socketName
        try server.createSession("anchor")
        try server.createSession("before")

        let identityReader = TmuxSessionKiller(
            pathResolver: { _ in .success(tmuxPath) }
        )
        let renamer = TmuxSessionRenamer(
            pathResolver: { _ in .success(tmuxPath) }
        )
        let before = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "before",
            socketName: socketName
        )
        let identity = try await identityReader.sessionIdentity(
            before,
            on: .local
        )

        try await renamer.rename(
            before,
            to: "it's after",
            expectedIdentity: identity,
            on: .local
        )
        #expect(try sessionNames(tmuxPath, socketName) == [
            "anchor", "it's after",
        ])
        var after = before
        after.name = "it's after"
        #expect(
            try await identityReader.sessionIdentity(after, on: .local)
                == identity
        )

        // A new session that reuses the old name is a different session.
        try server.createSession("before")
        await #expect {
            try await renamer.rename(
                before,
                to: "stolen",
                expectedIdentity: identity,
                on: .local
            )
        } throws: { error in
            error as? TmuxSessionRenameError == .sessionChanged(
                host: "localhost",
                session: "before"
            )
        }

        await #expect {
            try await renamer.rename(
                after,
                to: "anchor",
                expectedIdentity: identity,
                on: .local
            )
        } throws: { error in
            guard case let .commandFailed(_, session, _, message) =
                error as? TmuxSessionRenameError
            else { return false }
            return session == "it's after"
                && message.contains("duplicate session")
        }
        #expect(try sessionNames(tmuxPath, socketName) == [
            "anchor", "before", "it's after",
        ])

        try await renamer.rename(
            after,
            to: "-work",
            expectedIdentity: identity,
            on: .local
        )
        #expect(try sessionNames(tmuxPath, socketName) == [
            "-work", "anchor", "before",
        ])
    }

    private func sessionNames(
        _ tmuxPath: String,
        _ socketName: String
    ) throws -> [String] {
        let result = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "list-sessions", "-F", "#{session_name}",
            ],
            timeout: 5
        )
        #expect(result.status == 0)
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted()
    }
}
