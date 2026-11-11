import Foundation
import GhosthubTransport
import Testing
@testable import GhosthubHerdr

@Suite("Herdr attachment commands")
struct HerdrAttachmentInfoTests {
    @Test("local attachment targets one exact session without inheriting Herdr identity")
    func localAttachment() throws {
        let info = HerdrAttachmentInfo(
            sessionName: "review 'alpha'",
            isDefault: false,
            host: .local
        )

        let command = try info.attachCommand(herdrPath: "/bin/echo")
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec \(command)"]
        process.standardOutput = output

        try process.run()
        process.waitUntilExit()
        let stdout = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        #expect(command.contains("unset HERDR_ENV HERDR_SESSION"))
        #expect(command.contains("HERDR_CLIENT_SOCKET_PATH"))
        #expect(!command.contains("--remote"))
        #expect(process.terminationStatus == 0)
        #expect(stdout == "session attach review 'alpha'\n")
    }

    @Test("launch intent keeps attach separate from create and restart")
    func launchIntent() throws {
        let named = HerdrAttachmentInfo(
            sessionName: "review",
            isDefault: false,
            host: .local
        )
        let existing = try named.attachCommand(
            herdrPath: "/bin/echo",
            launchMode: .attachExisting
        )
        let launch = try named.attachCommand(
            herdrPath: "/bin/echo",
            launchMode: .launchOrAttach
        )
        let defaultLaunch = try HerdrAttachmentInfo(
            sessionName: "api",
            isDefault: true,
            host: .local
        ).attachCommand(
            herdrPath: "/bin/echo",
            launchMode: .launchOrAttach
        )
        let ordinaryNamedDefault = try HerdrAttachmentInfo(
            sessionName: "default",
            isDefault: false,
            host: .local
        ).attachCommand(
            herdrPath: "/bin/echo",
            launchMode: .launchOrAttach
        )

        #expect(try output(of: existing) == "session attach review\n")
        #expect(try output(of: launch) == "--session review\n")
        #expect(try output(of: defaultLaunch) == "\n")
        #expect(try output(of: ordinaryNamedDefault) == "--session default\n")
    }

    @Test("local attachment survives libghostty's exec shell wrapper")
    func localAttachmentThroughSurfaceShell() throws {
        let info = HerdrAttachmentInfo(
            sessionName: "default",
            isDefault: true,
            host: .local
        )
        let command = try info.attachCommand(herdrPath: "/usr/bin/true")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec \(command)"]

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test("remote attachment uses Ghosthub SSH routing and records nested status")
    func remoteAttachment() throws {
        let info = HerdrAttachmentInfo(
            sessionName: "review 'alpha'",
            isDefault: false,
            host: .ssh(SSHHostInfo(
                user: "dev",
                hostname: "build.example",
                port: 2222
            ))
        )

        let command = try info.attachCommand(
            herdrPath: "/opt/Herdr Tools/herdr",
            sshConnectionArguments: ["-F", "/tmp/ssh config"],
            remoteExitStatusPath: "/tmp/ghosthub herdr.status"
        )

        #expect(command.contains("/usr/bin/ssh"))
        #expect(command.contains("-tt"))
        #expect(command.contains("'BatchMode=yes'"))
        #expect(command.contains("-F"))
        #expect(command.contains("/tmp/ssh config"))
        #expect(command.contains("-p"))
        #expect(command.contains("2222"))
        #expect(command.contains("dev@build.example"))
        #expect(command.contains("ghosthub-ssh-herdr"))
        #expect(command.contains("/tmp/ghosthub herdr.status"))
        #expect(command.contains("HERDR_ACTIVE_WORKSPACE_ID"))
        #expect(command.contains("${SHELL:-/bin/sh}"))
        #expect(!command.contains("--remote"))
    }

    @Test("Windows hosts are outside native Herdr support")
    func windowsUnsupported() {
        let info = HerdrAttachmentInfo(
            sessionName: "default",
            isDefault: true,
            host: .ssh(SSHHostInfo(
                user: nil,
                hostname: "windows.example",
                port: nil,
                platform: .windows
            ))
        )

        #expect(throws: HerdrCommandError.unsupportedPlatform) {
            try info.attachCommand(herdrPath: "herdr")
        }
    }

    private func output(of command: String) throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec \(command)"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    }
}
