import GhosthubTransport
import Foundation
import Testing
@testable import GhosthubZellij

@Suite("Native Zellij attachment")
struct ZellijAttachmentInfoTests {
    @Test(
        "attachment passes one exact positional name and removes inherited identity",
        arguments: ["review 'one'", "-", "déploiement", "release; echo unwanted"]
    )
    func localAttachment(_ name: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("zellij")
        try """
        #!/bin/sh
        printf '<%s>\\n' "$@" "${ZELLIJ-unset}" "${ZELLIJ_PANE_ID-unset}" "${ZELLIJ_SESSION_NAME-unset}"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let command = try ZellijAttachmentInfo(
            sessionName: name,
            host: .local
        ).attachCommand(zellijPath: executable.path)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["ZELLIJ": "1", "ZELLIJ_PANE_ID": "7", "ZELLIJ_SESSION_NAME": "outer"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let received = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0)
        #expect(received == "<attach>\n<\(name)>\n<unset>\n<unset>\n<unset>\n")
    }

    @Test(
        "local Zellij inherits the login PATH, not the app's GUI PATH",
        arguments: [ZellijAttachmentLaunchMode.attachExisting, .create]
    )
    func localLoginPath(_ mode: ZellijAttachmentLaunchMode) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try "export PATH=\"$HOME/bin:$PATH\"\n".write(
            to: home.appendingPathComponent(".zprofile"),
            atomically: true,
            encoding: .utf8
        )
        let executable = home.appendingPathComponent("zellij")
        try "#!/bin/sh\nprintf '%s' \"$PATH\"\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let command = try ZellijAttachmentInfo(
            sessionName: "agents",
            host: .local
        ).attachCommand(zellijPath: executable.path, launchMode: mode)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // What an app opened from the Dock or Finder receives from launchd.
        process.environment = [
            "HOME": home.path,
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let path = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0)
        #expect(path.split(separator: ":").contains(Substring(bin.path)))
    }

    @Test(
        "attachment and creation reject names interpreted as flags or subcommands",
        arguments: ["", "-release", "--", "--create", "help", "options"]
    )
    func unattachableName(_ name: String) {
        for host in [
            CommandHost.local,
            .ssh(SSHHostInfo(user: nil, hostname: "example.test", port: nil)),
        ] {
            for mode in [ZellijAttachmentLaunchMode.attachExisting, .create] {
                #expect(throws: ZellijCommandError.unattachableSessionName(name)) {
                    try ZellijAttachmentInfo(sessionName: name, host: host)
                        .attachCommand(zellijPath: "/usr/bin/zellij", launchMode: mode)
                }
            }
        }
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
