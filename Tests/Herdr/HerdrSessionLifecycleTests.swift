import GhosthubWorkspace
import Testing
@testable import GhosthubHerdr

@Suite("Herdr session lifecycle commands")
struct HerdrSessionLifecycleTests {
    @Test("commands quote exact names and resolved paths")
    func commandConstruction() {
        let command = HerdrSessionLifecycle.command(
            action: .stop,
            name: "release.review",
            herdrPath: "/opt/Herdr Tools/herdr"
        )

        #expect(command.contains(HerdrSessionLifecycle.marker))
        #expect(command.contains("unset HERDR_ENV HERDR_SESSION"))
        #expect(command.contains(
            "'/opt/Herdr Tools/herdr' 'session' 'stop' 'release.review' '--json'"
        ))
    }

    @Test("banner noise is stripped from stop and delete envelopes")
    func parsesSuccess() {
        let expected = HerdrSessionRecord(
            name: "review",
            isDefault: false,
            state: .stopped,
            sessionDirectory: "/tmp/review",
            socketPath: "/tmp/review/herdr.sock"
        )
        let payload = """
        Last login: today
        GHOSTHUB_HERDR_SESSION_JSON
        {"session":{"name":"review","default":false,"running":false,"session_dir":"/tmp/review","socket_path":"/tmp/review/herdr.sock"},"stopped":true}
        """

        #expect(HerdrSessionLifecycle.parse(
            action: .stop,
            status: 0,
            stdout: payload,
            stderr: ""
        ) == .success(expected))

        #expect(HerdrSessionLifecycle.parse(
            action: .delete,
            status: 0,
            stdout: """
            GHOSTHUB_HERDR_SESSION_JSON
            {"session":{"name":"review","default":false,"running":false,"session_dir":"/tmp/review","socket_path":"/tmp/review/herdr.sock"},"deleted":true}
            """,
            stderr: ""
        ) == .success(expected))
    }

    @Test("structured CLI errors and malformed framing remain distinct")
    func parsesFailures() {
        #expect(HerdrSessionLifecycle.parse(
            action: .stop,
            status: 1,
            stdout: """
            GHOSTHUB_HERDR_SESSION_JSON
            {"error":{"code":"session_stop_failed","message":"already stopped"}}
            """,
            stderr: ""
        ) == .failure(.commandFailed(
            status: 1,
            code: "session_stop_failed",
            message: "already stopped"
        )))
        #expect(HerdrSessionLifecycle.parse(
            action: .delete,
            status: 127,
            stdout: "",
            stderr: "not found"
        ) == .failure(.unavailable))
        #expect(HerdrSessionLifecycle.parse(
            action: .delete,
            status: 0,
            stdout: "{}",
            stderr: ""
        ) == .failure(.missingMarker))
    }
}
