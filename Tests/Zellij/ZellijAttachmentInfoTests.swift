import GhosthubTransport
import Testing
@testable import GhosthubZellij

@Suite("Native Zellij attachment")
struct ZellijAttachmentInfoTests {
    @Test("local attachment removes inherited Zellij identity")
    func localAttachment() throws {
        let command = try ZellijAttachmentInfo(
            sessionName: "release work",
            host: .local
        ).attachCommand(zellijPath: "/opt/homebrew/bin/zellij")

        #expect(command.contains("unset ZELLIJ ZELLIJ_PANE_ID ZELLIJ_SESSION_NAME"))
        #expect(command.contains("attach"))
        #expect(command.contains("release work"))
        #expect(!command.contains("--create"))
    }

    @Test("attachment terminates options before a leading-dash name")
    func attachmentLeadingDashName() throws {
        let command = try ZellijAttachmentInfo(
            sessionName: "-release",
            host: .local
        ).attachCommand(zellijPath: "/usr/bin/zellij")

        #expect(command.contains(
            #"'\''attach'\'' '\''--'\'' '\''-release'\''"#
        ))
    }

    @Test("new session refuses live and resurrectable name collisions")
    func create() throws {
        let command = try ZellijAttachmentInfo(
            sessionName: "new-session",
            host: .local
        ).attachCommand(
            zellijPath: "/usr/local/bin/zellij",
            launchMode: .create
        )

        #expect(command.contains("--session"))
        #expect(command.contains("new-session"))
        #expect(!command.contains("'attach'"))
    }

    @Test("creation joins a leading-dash name to the session option")
    func creationLeadingDashName() throws {
        let command = try ZellijAttachmentInfo(
            sessionName: "-release",
            host: .local
        ).attachCommand(
            zellijPath: "/usr/bin/zellij",
            launchMode: .create
        )

        #expect(command.contains("'--session=-release'"))
        #expect(!command.contains("'--session' '-release'"))
    }

    @Test("remote attachment allocates a PTY and uses the account shell")
    func remoteAttachment() throws {
        let command = try ZellijAttachmentInfo(
            sessionName: "ops",
            host: .ssh(SSHHostInfo(
                user: "dev",
                hostname: "example.test",
                port: 2222
            ))
        ).attachCommand(
            zellijPath: "/usr/bin/zellij",
            sshConnectionArguments: ["-o", "ControlPath=/tmp/control"]
        )

        #expect(command.contains("-tt"))
        #expect(command.contains("dev@example.test"))
        #expect(command.contains("ControlPath=/tmp/control"))
        #expect(command.contains("/usr/bin/zellij"))
    }

    @Test("kill targets one shell-quoted session name")
    func killCommand() {
        #expect(ZellijSessionLifecycle.killCommand(
            zellijPath: "/usr/bin/zellij",
            sessionName: "release work"
        ) == "'/usr/bin/zellij' 'kill-session' '--' 'release work'")
    }

    @Test("kill terminates options before a leading-dash name")
    func killLeadingDashName() {
        #expect(ZellijSessionLifecycle.killCommand(
            zellijPath: "/usr/bin/zellij",
            sessionName: "-release"
        ) == "'/usr/bin/zellij' 'kill-session' '--' '-release'")
    }
}
