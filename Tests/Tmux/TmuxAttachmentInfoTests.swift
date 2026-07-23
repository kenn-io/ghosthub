import Foundation
import Testing
@testable import GhosthubTmux

@Suite("Native tmux attachment")
struct TmuxAttachmentInfoTests {
    @Test("host display names omit the default SSH port")
    func hostDisplayNames() {
        #expect(
            SSHHostInfo(
                user: "alice", hostname: "example.com", port: 22
            ).displayName == "alice@example.com"
        )
        #expect(
            SSHHostInfo(
                user: "alice", hostname: "example.com", port: 2222
            ).displayName == "alice@example.com:2222"
        )
        #expect(TmuxHost.local.displayName == "localhost")
    }

    @Test("local attachment normalizes only tmux presentation styles")
    func localAttachCommand() {
        let info = TmuxAttachmentInfo(
            sessionName: "doc bank's work",
            host: .local
        )

        let command = info.attachCommand(
            tmuxPath: "/Applications/My Tools/tmux"
        )

        #expect(command.contains("unset TMUX TMUX_PANE"))
        #expect(command.contains("set-option"))
        #expect(command.contains("status-style"))
        #expect(command.contains("message-style"))
        #expect(command.contains("message-command-style"))
        #expect(command.contains("reverse"))
        #expect(command.contains("exec"))
        #expect(command.contains("attach-session"))
        #expect(command.contains("=doc bank"))
        #expect(!command.contains("-CC"))
        #expect(!command.contains("capture-pane"))
        #expect(!command.contains("bind-key"))
        #expect(!command.contains("unbind-key"))
        #expect(!command.contains("'mouse'"))
    }

    @Test("remote attachment adds keepalives and transport-only retry")
    func remoteAttachCommand() {
        let info = TmuxAttachmentInfo(
            sessionName: "docbank",
            host: .ssh(SSHHostInfo(
                user: "wesm", hostname: "build-box", port: 2222
            ))
        )

        let command = info.attachCommand(tmuxPath: "/opt/bin/tmux")

        #expect(command.contains("'/usr/bin/ssh' '-tt'"))
        #expect(command.contains("'ServerAliveInterval=15'"))
        #expect(command.contains("'ServerAliveCountMax=3'"))
        #expect(command.contains("'TCPKeepAlive=yes'"))
        #expect(command.contains("'wesm@build-box'"))
        #expect(command.contains("'attach-session'"))
        #expect(command.contains("'-E'"))
        #expect(command.contains("=docbank"))
        #expect(command.contains("status-style"))
        #expect(command.contains("message-style"))
        #expect(command.contains("message-command-style"))
        #expect(command.contains("[ \"$status\" -eq 255 ] || exit \"$status\""))
        #expect(!command.contains("-CC"))
        #expect(!command.contains("KexAlgorithms"))
        #expect(!command.contains("bind-key"))
        #expect(!command.contains("unbind-key"))
    }

    @Test("demo SSH arguments isolate config, trust, and routing")
    func demoSSHArguments() {
        let scratch = "/tmp/ghosthub demo"
        let arguments = tmuxSSHConnectionArguments(environment: [
            "GHOSTHUB_DEMO_SCRATCH": scratch,
            "GHOSTHUB_DEMO_SSH_DIR": "\(scratch)/ssh",
        ])
        let info = TmuxAttachmentInfo(
            sessionName: "remote",
            host: .ssh(SSHHostInfo(
                user: nil, hostname: "ghosthub-demo-remote", port: nil
            ))
        )
        let command = info.attachCommand(
            sshConnectionArguments: arguments
        )

        #expect(command.contains("'-F' '/tmp/ghosthub demo/ssh/config'"))
        #expect(command.contains(
            "'UserKnownHostsFile=/tmp/ghosthub demo/ssh/known_hosts'"
        ))
        #expect(command.contains("'GlobalKnownHostsFile=/dev/null'"))
        #expect(command.contains("'StrictHostKeyChecking=yes'"))
        #expect(command.contains("'ProxyCommand=none'"))
        #expect(command.contains("'ProxyJump=none'"))
    }

    @Test("explicit named creation uses create-or-attach mode")
    func explicitCreateOrAttachCommand() {
        let info = TmuxAttachmentInfo(
            sessionName: "release-work",
            host: .local,
            launchMode: .create
        )

        let command = info.attachCommand(
            tmuxPath: "/opt/bin/tmux"
        )

        #expect(command.contains("new-session"))
        #expect(command.contains("'-d'"))
        #expect(command.contains("'-E'"))
        #expect(command.contains("release-work"))
        #expect(command.contains("attach-session"))
        #expect(command.contains("status-style"))
    }

    @Test("remote named creation becomes attach-only after one create phase")
    func remoteCreationIsOneShot() {
        let info = TmuxAttachmentInfo(
            sessionName: "release-work",
            host: .ssh(SSHHostInfo(
                user: "wesm", hostname: "build-box", port: nil
            )),
            launchMode: .create
        )

        let command = info.attachCommand(
            tmuxPath: "/opt/bin/tmux",
            workingDirectory: "/code/release"
        )

        #expect(command.contains("new-session"))
        #expect(command.contains("attach-session"))
        #expect(command.contains("-d"))
        #expect(command.contains("-T"))
        #expect(command.contains("-tt"))
        #expect(command.contains("/code/release"))
        #expect(
            command.components(separatedBy: "new-session").count == 2
        )
        #expect(
            command.components(
                separatedBy: "SSH disconnected; reconnecting"
            ).count == 2
        )
    }

    @Test("attach retries never rerun the completed create phase")
    func reconnectDoesNotRepeatCreation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let createCounter = directory.appendingPathComponent("create-count")
        let attachCounter = directory.appendingPathComponent("attach-count")
        let fakeCreate = directory.appendingPathComponent("fake-create")
        let fakeAttach = directory.appendingPathComponent("fake-attach")
        try """
        #!/bin/sh
        printf x >> "$GHOSTHUB_CREATE_COUNTER"
        exit 0
        """.write(to: fakeCreate, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        count=0
        [ ! -f "$GHOSTHUB_ATTACH_COUNTER" ] || count=$(wc -c < "$GHOSTHUB_ATTACH_COUNTER")
        printf x >> "$GHOSTHUB_ATTACH_COUNTER"
        [ "$count" -gt 0 ] && exit 0
        exit 255
        """.write(to: fakeAttach, atomically: true, encoding: .utf8)
        for executable in [fakeCreate, fakeAttach] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
        }
        let createCommand = shellQuotedCommandArgument(fakeCreate.path)
        let attachCommand = [
            "/bin/sh", "-c", TmuxAttachmentInfo.sshReconnectScript,
            "ghosthub-test", fakeAttach.path,
        ].map(shellQuotedCommandArgument).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", TmuxAttachmentInfo.remoteCreateThenAttachScript,
            "ghosthub-test", createCommand, attachCommand,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GHOSTHUB_CREATE_COUNTER": createCounter.path,
            "GHOSTHUB_ATTACH_COUNTER": attachCounter.path,
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(
            try String(contentsOf: createCounter, encoding: .utf8) == "x"
        )
        #expect(
            try String(contentsOf: attachCounter, encoding: .utf8) == "xx"
        )
    }

    @Test("SSH status 255 retries, then clean tmux exit stops")
    func reconnectsOnlyTransportFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = directory.appendingPathComponent("count")
        let fake = directory.appendingPathComponent("fake-ssh")
        try """
        #!/bin/sh
        count=0
        [ ! -f "$GHOSTHUB_TEST_COUNTER" ] || count=$(cat "$GHOSTHUB_TEST_COUNTER")
        count=$((count + 1))
        printf '%s' "$count" > "$GHOSTHUB_TEST_COUNTER"
        [ "$count" -gt 1 ] && exit 0
        exit 255
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", TmuxAttachmentInfo.sshReconnectScript,
            "ghosthub-test", fake.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GHOSTHUB_TEST_COUNTER": counter.path,
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: counter, encoding: .utf8) == "2")
    }

    @Test("ordinary remote-command failure does not reconnect")
    func doesNotRetryTmuxFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = directory.appendingPathComponent("count")
        let fake = directory.appendingPathComponent("fake-ssh")
        try """
        #!/bin/sh
        printf x >> "$GHOSTHUB_TEST_COUNTER"
        exit 1
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fake.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", TmuxAttachmentInfo.sshReconnectScript,
            "ghosthub-test", fake.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GHOSTHUB_TEST_COUNTER": counter.path,
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 1)
        #expect(try String(contentsOf: counter, encoding: .utf8) == "x")
    }

    @Test("host identity is codable")
    func hostIdentityCodable() throws {
        let original = TmuxHost.ssh(SSHHostInfo(
            user: "bob", hostname: "server.io", port: 2222
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TmuxHost.self, from: data)
        #expect(original == decoded)
    }
}
