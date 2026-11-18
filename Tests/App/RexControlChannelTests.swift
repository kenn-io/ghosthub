import Foundation
import GhosthubBackendTerminal
import Testing
@testable import GhosthubApp

@MainActor
@Suite("Rex control channel", .timeLimit(.minutes(1)))
struct RexControlChannelTests {
    /// Stands in for `kwt rex control` behind a login shell that prints a
    /// banner: writes a view, answers each request, refuses `fail`, never
    /// answers `hang`, writes junk on `junk`, and ends the session on `end`.
    private static let fakeKwt = #"""
    echo 'Welcome to devbox'
    printf '%s\n' 'GHOSTHUB_REX_CONTROL'
    printf '%s\n' '{"type":"view","terminals":{},"view":{"revision":1,"session_id":"session:s","label":"work","windows":[]}}'
    while IFS= read -r line; do
      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
      case "$line" in
        *'"method":"fail"'*) printf '{"type":"reply","id":%s,"error":{"code":"request_failed","message":"no"}}\n' "$id" ;;
        *'"method":"hang"'*) ;;
        *'"method":"junk"'*) echo 'not a message' ;;
        *'"method":"shell"'*) printf '%s\n' "$SHELL" >&2; exit 3 ;;
        *'"method":"end"'*) printf '{"type":"reply","id":%s,"result":{}}\n{"type":"ended"}\n' "$id"; exit 0 ;;
        *'"method":"crash"'*) echo 'rex: server went away' >&2; exit 3 ;;
        *) printf '{"type":"reply","id":%s,"result":{}}\n' "$id" ;;
      esac
    done
    """#

    private final class Recorder {
        var views: [RexControlView] = []
        var exits: [RexControlChannelExit] = []
    }

    private func start(
        accountShell: String = AccountCommandRunner.loginShell()
    ) throws -> (RexControlChannel, Recorder) {
        let channel = RexControlChannel(command: Self.fakeKwt, accountShell: accountShell)
        let recorder = Recorder()
        channel.onView = { recorder.views.append($0) }
        channel.onExit = { recorder.exits.append($0) }
        try channel.start()
        return (channel, recorder)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("views arrive, requests are answered, and the end of the session is reported")
    func session() async throws {
        let (channel, recorder) = try start()
        await waitUntil { !recorder.views.isEmpty }
        #expect(recorder.views.first?.sessionLabel == "work")
        try await channel.send(method: "session.focus_next_pane", params: [:])
        try await channel.send(method: "end", params: ["block_id": "block:a"])
        await waitUntil { !recorder.exits.isEmpty }
        #expect(recorder.exits == [.ended])
    }

    @Test("a refused request throws Rex's error")
    func refused() async throws {
        let (channel, _) = try start()
        defer { channel.stop() }
        await #expect(throws: RexControlError(code: "request_failed", message: "no")) {
            try await channel.send(method: "fail", params: [:])
        }
    }

    @Test("kwt exiting without ending the session fails with its message")
    func crash() async throws {
        let (channel, recorder) = try start()
        await #expect(throws: CancellationError.self) {
            try await channel.send(method: "crash", params: [:])
        }
        await waitUntil { !recorder.exits.isEmpty }
        #expect(recorder.exits == [.failed("rex: server went away")])
    }

    @Test("a line after the marker that is not a message fails the channel")
    func unreadable() async throws {
        let (channel, recorder) = try start()
        await #expect(throws: CancellationError.self) {
            try await channel.send(method: "junk", params: [:])
        }
        #expect(recorder.exits == [.failed("Cannot read the Rex window layout.")])
    }

    @Test("kwt starts with the account's shell, as Rex discovery does")
    func accountShell() async throws {
        let (channel, recorder) = try start(accountShell: "/bin/account-shell")
        await #expect(throws: CancellationError.self) {
            try await channel.send(method: "shell", params: [:])
        }
        await waitUntil { !recorder.exits.isEmpty }
        #expect(recorder.exits == [.failed("/bin/account-shell")])
    }

    @Test("stopping cancels waiting requests and reports no exit")
    func stop() async throws {
        let (channel, recorder) = try start()
        await waitUntil { !recorder.views.isEmpty }
        let reply = Task { try await channel.send(method: "hang", params: [:]) }
        // Let the request reach kwt, so stopping cancels a waiting request.
        try await Task.sleep(for: .milliseconds(50))
        channel.stop()
        await #expect(throws: CancellationError.self) { try await reply.value }
        await #expect(throws: CancellationError.self) {
            try await channel.send(method: "session.focus_next_pane", params: [:])
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.exits.isEmpty)
    }
}
