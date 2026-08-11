import Testing
@testable import GhosthubZellij

@Suite("Zellij session inventory")
struct ZellijSessionListTests {
    @Test("unformatted output becomes active session names")
    func parsesNames() {
        #expect(
            ZellijSessionList.parse(
                status: 0,
                stdout: """
                Last login: Mon Aug 10 08:30:00 on ttys001
                GHOSTHUB_ZELLIJ_SESSIONS
                api [Created 2m 3s ago]
                release work [Created 1h 4m ago] (current)
                old work [Created 3d 1h ago] (EXITED - attach to resurrect)

                """,
                stderr: ""
            ) == .available(["api", "release work"])
        )
    }

    @Test("inventory command frames Zellij output")
    func commandFramesOutput() {
        #expect(
            ZellijSessionList.command(zellijPath: "/opt/Zellij Bin/zellij")
                == "printf '\\n%s\\n' 'GHOSTHUB_ZELLIJ_SESSIONS'; "
                + "printf '\\n%s\\n' 'GHOSTHUB_ZELLIJ_ERRORS' >&2; "
                + "exec '/opt/Zellij Bin/zellij' 'list-sessions' "
                + "'--no-formatting'"
        )
    }

    @Test("missing Zellij is an unavailable optional capability")
    func missingExecutable() {
        #expect(
            ZellijSessionList.parse(
                status: 127,
                stdout: "",
                stderr: "zellij: command not found"
            ) == .unavailable
        )
    }

    @Test("a no-sessions response is an available empty inventory")
    func emptyInventory() {
        #expect(
            ZellijSessionList.parse(
                status: 1,
                stdout: "",
                stderr: """
                shell startup warning
                GHOSTHUB_ZELLIJ_ERRORS
                No active zellij sessions found.

                """
            ) == .available([])
        )
    }

    @Test("unrecognized output remains a visible inventory failure")
    func malformedInventory() {
        #expect(
            ZellijSessionList.parse(
                status: 0,
                stdout: "login banner\nGHOSTHUB_ZELLIJ_SESSIONS\nunexpected output\n",
                stderr: ""
            ) == .failure(.malformedInventory(line: "unexpected output"))
        )
    }

    @Test("successful output without the inventory marker is rejected")
    func missingMarker() {
        #expect(
            ZellijSessionList.parse(
                status: 0,
                stdout: "api [Created 2m 3s ago]\n",
                stderr: ""
            ) == .failure(.missingMarker)
        )
    }
}
