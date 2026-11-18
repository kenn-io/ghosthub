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

    private func pane(
        _ block: String,
        window: String = "window:1",
        windowLabel: String = "Window 7fca5d29",
        session: String = "session:a",
        sessionLabel: String = "work",
        name: String = "zsh ~",
        focused: Bool = false
    ) -> String {
        """
        {"session_id":"\(session)","session_label":"\(sessionLabel)","window_id":"\(window)",
         "window_label":"\(windowLabel)","window_index":1,"block_id":"\(block)",
         "label":"shell","name":"\(name)","focused":\(focused)}
        """
    }

    @Test("each Rex window is one row addressed by its window ID")
    func windows() {
        let result = RexInventory.parse(status: 0, stdout: listing([
            pane("block:aa", window: "window:1", windowLabel: "editor"),
            pane("block:bb", window: "window:1", windowLabel: "editor"),
            pane(
                "block:cc",
                window: "window:2",
                windowLabel: "Window 8be734c2",
                sessionLabel: "logs",
                name: "tail -f app.log"
            ),
        ].joined(separator: ",")), stderr: "")
        #expect(result == .available([
            BackendTerminalSummary(
                kind: .rex, address: "window:1", title: "editor", detail: "work · 2 panes"
            ),
            BackendTerminalSummary(
                kind: .rex, address: "window:2", title: "tail -f app.log",
                detail: "logs · 1 pane"
            ),
        ]))
    }

    @Test("a window with Rex's default label is named for its focused pane")
    func defaultLabel() {
        let result = RexInventory.parse(status: 0, stdout: listing([
            pane("block:aa", name: "zsh ~"),
            pane("block:bb", name: "vim main.go", focused: true),
        ].joined(separator: ",")), stderr: "")
        #expect(result == .available([
            BackendTerminalSummary(
                kind: .rex, address: "window:1", title: "vim main.go", detail: "work · 2 panes"
            ),
        ]))
    }

    @Test("a window ID listed under two sessions is rejected")
    func windowInTwoSessions() {
        let result = RexInventory.parse(status: 0, stdout: listing([
            pane("block:aa", session: "session:a"),
            pane("block:bb", session: "session:b"),
        ].joined(separator: ",")), stderr: "")
        #expect(result == .failure(.malformedJSON(.rex)))
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

    @Test("block and window IDs that could act as options or repeat are rejected", arguments: [
        #"{"window_id":"window:1","block_id":"--help"}"#,
        #"{"window_id":"window:1","block_id":"block:a b"}"#,
        #"{"window_id":"window:1","block_id":"block:aa"},{"window_id":"window:1","block_id":"block:aa"}"#,
        #"{"window_id":"--help","block_id":"block:aa"}"#,
        #"{"block_id":"block:aa"}"#,
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

    @Test("a local Rex window is followed through kwt rex control from the login shell")
    func localControl() throws {
        let command = try BackendTerminalAttachmentInfo(
            terminal: BackendTerminalSummary(kind: .rex, address: "window:01a1-aa"),
            host: .local
        ).controlCommand(executablePath: "/bin/echo")
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
        #expect(output == "GHOSTHUB_REX_CONTROL\nrex control window:01a1-aa\n")
    }

    @Test("a remote Rex window is followed over ssh without a terminal")
    func remoteControl() throws {
        let host = CommandHost.ssh(SSHHostInfo(user: "me", hostname: "devbox", port: 2222))
        let command = try BackendTerminalAttachmentInfo(
            terminal: BackendTerminalSummary(kind: .rex, address: "window:01a1-aa"),
            host: host
        ).controlCommand(
            executablePath: "/home/me/.ghosthub/helpers/kwt/abc/kwt",
            sshConnectionArguments: ["-o", "ControlPath=/tmp/c"]
        )
        #expect(command.contains("/usr/bin/ssh"))
        #expect(!command.contains("-tt"))
        #expect(command.contains("me@devbox"))
        #expect(command.contains("2222"))
        #expect(command.contains("ControlPath=/tmp/c"))
        #expect(command.contains("control"))
        #expect(command.contains("window:01a1-aa"))
    }

    @Test("an address that is not a Rex window never reaches kwt rex control", arguments: [
        "--help", "block:01a1-aa", "window:a b",
    ])
    func invalidRexWindow(_ address: String) {
        #expect(throws: BackendTerminalCommandError.invalidAddress(.rex, address: address)) {
            try BackendTerminalAttachmentInfo(
                terminal: BackendTerminalSummary(kind: .rex, address: address),
                host: .local
            ).controlCommand(executablePath: "/kwt")
        }
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
