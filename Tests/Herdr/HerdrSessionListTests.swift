import GhosthubWorkspace
import Testing
@testable import GhosthubHerdr

@Suite("Herdr session discovery")
struct HerdrSessionListTests {
    @Test("capability probe resolves an exact executable through the login environment")
    func executableProbe() {
        let command = HerdrExecutable.command()

        #expect(command.contains("command -v herdr"))
        #expect(command.contains("unset HERDR_ENV HERDR_SESSION"))
        #expect(command.contains("HERDR_CLIENT_SOCKET_PATH"))
        #expect(command.contains("HERDR_ACTIVE_PANE_ID"))
        #expect(
            HerdrExecutable.parse(
                status: 0,
                stdout: "login banner\nGHOSTHUB_HERDR_PATH\n/opt/homebrew/bin/herdr\n",
                stderr: ""
            ) == .available("/opt/homebrew/bin/herdr")
        )
    }

    @Test("missing or unresolved executables are normally unavailable")
    func executableUnavailable() {
        #expect(
            HerdrExecutable.parse(status: 127, stdout: "", stderr: "not found")
                == .unavailable
        )
        #expect(
            HerdrExecutable.parse(status: 0, stdout: "login banner\n", stderr: "")
                == .unavailable
        )
    }

    @Test("capability command failures remain diagnosable")
    func executableFailure() {
        #expect(
            HerdrExecutable.parse(status: 42, stdout: "", stderr: "shell failed")
                == .failure(.commandFailed(status: 42, stderr: "shell failed"))
        )
    }

    @Test("banner noise and additive fields preserve every session state")
    func parsesSessions() {
        let result = HerdrSessionList.parse(
            status: 0,
            stdout: """
            Last login: today
            GHOSTHUB_HERDR_JSON
            {"sessions":[
              {"name":"default","default":true,"running":true,"session_dir":"/tmp/default","socket_path":"/tmp/default/herdr.sock"},
              {"name":"review","default":false,"running":false,"session_dir":"/tmp/review","socket_path":"/tmp/review/herdr.sock","future":"ignored"}
            ]}
            """,
            stderr: ""
        )

        #expect(result == .available([
            HerdrSessionSummary(
                name: "default",
                isDefault: true,
                state: .running
            ),
            HerdrSessionSummary(
                name: "review",
                isDefault: false,
                state: .stopped
            ),
        ]))

        #expect(HerdrSessionList.parseRecords(
            status: 0,
            stdout: """
            GHOSTHUB_HERDR_JSON
            {"sessions":[{"name":"review","default":false,"running":false,"session_dir":"/tmp/review","socket_path":"/tmp/review/herdr.sock"}]}
            """,
            stderr: ""
        ) == .success([
            HerdrSessionRecord(
                name: "review",
                isDefault: false,
                state: .stopped,
                sessionDirectory: "/tmp/review",
                socketPath: "/tmp/review/herdr.sock"
            ),
        ]))
    }

    @Test("list command uses the resolved binary and scrubs enclosing Herdr identity")
    func listCommand() {
        let command = HerdrSessionList.command(
            herdrPath: "/opt/Herdr Tools/herdr"
        )

        #expect(command.contains("unset HERDR_ENV HERDR_SESSION"))
        #expect(command.contains("HERDR_ACTIVE_PANE_CWD"))
        #expect(command.contains("'/opt/Herdr Tools/herdr'"))
        #expect(command.contains("'session' 'list' '--json'"))
        #expect(command.contains(HerdrSessionList.marker))
    }

    @Test("missing Herdr is silent while malformed output and failures are distinct")
    func discoveryFailures() {
        #expect(
            HerdrSessionList.parse(status: 127, stdout: "", stderr: "not found")
                == .unavailable
        )
        #expect(
            HerdrSessionList.parse(status: 0, stdout: "{}", stderr: "")
                == .failure(.missingMarker)
        )
        #expect(
            HerdrSessionList.parse(
                status: 0,
                stdout: "GHOSTHUB_HERDR_JSON\nnot json",
                stderr: ""
            ) == .failure(.malformedJSON)
        )
        #expect(
            HerdrSessionList.parse(status: 3, stdout: "", stderr: "bad socket")
                == .failure(.commandFailed(status: 3, stderr: "bad socket"))
        )
    }
}
