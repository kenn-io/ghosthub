import Foundation
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubBackendTerminal

@Suite("Rex inventory")
struct RexInventoryTests {
    private func listing(_ terminals: String, status: String = "running") -> String {
        """
        Last login: Tue Nov 10
        GHOSTHUB_REX_JSON
        {"status":"\(status)","terminals":[\(terminals)]}
        """
    }

    @Test("Rex terminal blocks become attachable terminals named by their program title")
    func runningServer() {
        let result = RexInventory.parse(status: 0, stdout: listing("""
        {"session_id":"session:a","session_label":"work","window_id":"window:1",
         "window_label":"editor","window_index":1,"block_id":"block:01a1-aa",
         "label":"shell","title":"vim main.go","focused":true},
        {"session_id":"session:a","session_label":"work","window_id":"window:1",
         "window_label":"editor","window_index":1,"block_id":"block:01a1-bb",
         "label":"logs","title":""}
        """), stderr: "")
        #expect(result == .available([
            BackendTerminalSummary(
                kind: .rex, address: "block:01a1-aa",
                title: "vim main.go", detail: "work / editor"
            ),
            BackendTerminalSummary(
                kind: .rex, address: "block:01a1-bb",
                title: "logs", detail: "work / editor"
            ),
        ]))
    }

    @Test("a host without Rex, or with its server stopped, is silent", arguments: [
        "not_installed", "not_running",
    ])
    func absentRex(_ status: String) {
        #expect(RexInventory.parse(status: 0, stdout: listing("", status: status), stderr: "")
            == .unavailable)
    }

    @Test("a host without Ghosthub's kwt is silent")
    func missingKwt() {
        #expect(RexInventory.parse(status: 127, stdout: "", stderr: "") == .unavailable)
    }

    @Test("block IDs that could act as options or repeat are rejected", arguments: [
        #"{"block_id":"--help"}"#,
        #"{"block_id":"block:a b"}"#,
        #"{"block_id":"block:aa"},{"block_id":"block:aa"}"#,
    ])
    func invalidBlocks(_ terminals: String) {
        #expect(RexInventory.parse(status: 0, stdout: listing(terminals), stderr: "")
            == .failure(.malformedJSON(.rex)))
    }

    @Test("failures name kwt and keep its message")
    func failures() {
        let result = RexInventory.parse(
            status: 1, stdout: "", stderr: "Error: unknown command \"rex\" for \"kwt\""
        )
        #expect(result == .failure(.commandFailed(
            .rex, status: 1, stderr: "Error: unknown command \"rex\" for \"kwt\""
        )))
        #expect(RexInventory.parse(status: 0, stdout: "{}", stderr: "")
            == .failure(.missingMarker(.rex)))
    }

    @Test("inventory refuses a pinned kwt that is missing instead of searching PATH")
    func inventoryCommand() throws {
        let command = RexInventory.command(
            kwtPrelude: "ghosthub_kwt_path='/nonexistent/\(UUID().uuidString)/kwt'; "
        )
        let result = try runShell(command.replacingOccurrences(
            of: "exec \"$ghosthub_kwt_path\" rex ls --json", with: "echo ran"
        ))
        // The pinned path does not exist, so the command reports a
        // missing helper instead of falling back to PATH.
        #expect(result.status == 127)
    }

    private func runShell(_ command: String) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

@Suite("Backend terminal attachment")
struct BackendTerminalAttachmentInfoTests {
    private let rexTerminal = BackendTerminalSummary(kind: .rex, address: "block:01a1-aa")

    @Test("a local Rex terminal attaches through kwt from the account login shell")
    func localRex() throws {
        let command = try BackendTerminalAttachmentInfo(terminal: rexTerminal, host: .local)
            .attachCommand(executablePath: "/bin/echo")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["SHELL": "/bin/sh", "HOME": home.path, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        #expect(output == "rex attach block:01a1-aa\n")
    }

    @Test("a remote terminal attaches over ssh with a terminal and records the remote exit")
    func remote() throws {
        let host = CommandHost.ssh(SSHHostInfo(user: "me", hostname: "devbox", port: nil))
        let command = try BackendTerminalAttachmentInfo(terminal: rexTerminal, host: host)
            .attachCommand(
                executablePath: "/home/me/.ghosthub/helpers/kwt/abc/kwt",
                sshConnectionArguments: ["-o", "ControlPath=/tmp/c"],
                remoteExitStatusPath: "/tmp/status"
            )
        #expect(command.contains("/usr/bin/ssh"))
        #expect(command.contains("-tt"))
        #expect(command.contains("me@devbox"))
        #expect(command.contains("ControlPath=/tmp/c"))
        #expect(command.contains("/tmp/status"))
        #expect(command.contains("rex"))
    }

    @Test("a Herdr core terminal attaches by address without TUI session commands")
    func herdrCore() throws {
        let command = try BackendTerminalAttachmentInfo(
            terminal: BackendTerminalSummary(kind: .herdrCore, address: "t7"),
            host: .local
        ).attachCommand(executablePath: "/bin/echo")
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec \(command)"]
        process.environment = ["HERDR_ENV": "1", "PATH": "/usr/bin:/bin"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        )
        #expect(output == "attach t7\n")
    }

    @Test("an address that is not a Rex block never reaches kwt")
    func invalidRexAddress() {
        #expect(throws: BackendTerminalCommandError.invalidAddress(.rex, address: "--version")) {
            try BackendTerminalAttachmentInfo(
                terminal: BackendTerminalSummary(kind: .rex, address: "--version"),
                host: .local
            ).attachCommand(executablePath: "/kwt")
        }
    }
}
