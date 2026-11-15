import GhosthubTransport
import Testing

@Suite("SSH session refusal")
struct SSHSessionRefusalTests {
    @Test("a refused session is reported as the SSH connection, not the tool")
    func refusalNamesTheConnection() {
        let message = SSHSessionRefusal.describeCommandFailure(
            tool: "Zellij",
            status: 255,
            detail: """
            mux_client_request_session: session request failed: Session open refused by peer
            Connection closed by UNKNOWN port 65535
            """
        )

        #expect(message == "The SSH connection to this host refused another session. "
            + "Zellij did not run.")
    }

    @Test("other failures keep the tool's own status and diagnostic")
    func otherFailuresNameTheTool() {
        #expect(SSHSessionRefusal.describeCommandFailure(
            tool: "Herdr",
            status: 255,
            detail: "Permission denied (publickey)."
        ) == "Herdr exited with status 255: Permission denied (publickey).")
        #expect(SSHSessionRefusal.describeCommandFailure(
            tool: "Herdr",
            status: 2,
            detail: ""
        ) == "Herdr exited with status 2.")
    }

    @Test("the refusal text from a remote command that exited normally does not match")
    func refusalRequiresTheSSHClientStatus() {
        #expect(SSHSessionRefusal.matches(
            status: 1,
            output: "mux_client_request_session: session request failed: "
                + "Session open refused by peer"
        ) == false)
    }
}
