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

    @Test("presentation styles target only the exact selected session")
    func presentationStylesUseExactSessionTarget() {
        let command = TmuxAttachmentInfo(
            sessionName: "alpha",
            host: .local
        ).attachCommand(tmuxPath: "/opt/homebrew/bin/tmux")

        #expect(
            command.components(separatedBy: "=alpha:").count - 1 == 3
        )
    }

    @Test("protected attachment leads kwt to the resolved tmux")
    func protectedAttachExportsResolvedTmuxDirectory() {
        let command = TmuxAttachmentInfo(
            sessionName: "pr-32",
            host: .local,
            socketName: "kwt-pr-0123456789abcdef",
            protectedWorkspacePath: "/worktrees/pr-32"
        ).attachCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            kwtPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        )

        // kwt looks tmux up by name, so the directory has to precede whatever
        // PATH a Finder-launched app inherited.
        #expect(command.contains("/opt/homebrew/bin"))
        let beforeKwt = command
            .components(separatedBy: "Helpers/kwt")
            .first ?? ""
        #expect(beforeKwt.contains("export PATH"))
    }

    @Test("an unresolved tmux name contributes no PATH entry")
    func protectedAttachSkipsPathForBareTmuxName() {
        let command = TmuxAttachmentInfo(
            sessionName: "pr-32",
            host: .local,
            socketName: "kwt-pr-0123456789abcdef",
            protectedWorkspacePath: "/worktrees/pr-32"
        ).attachCommand(
            tmuxPath: "tmux",
            kwtPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        )

        #expect(!command.contains("export PATH"))
    }

    @Test("ordinary local attachment does not rewrite PATH")
    func ordinaryAttachLeavesPathAlone() {
        let command = TmuxAttachmentInfo(
            sessionName: "alpha",
            host: .local
        ).attachCommand(tmuxPath: "/opt/homebrew/bin/tmux")

        #expect(!command.contains("export PATH"))
    }

    @Test("ordinary local worktree attaches through kwt without a handoff")
    func localWorktreeAttachesThroughKwt() {
        let command = TmuxAttachmentInfo(
            sessionName: "kwt-widget-feature",
            host: .local,
            workspacePath: "/worktrees/widget's feature"
        ).attachCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            kwtPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        )

        #expect(command.contains(
            "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        ))
        #expect(command.contains("open"))
        #expect(command.contains("/worktrees/widget"))
        #expect(command.contains("exec"))
        #expect(!command.contains("--start-session"))
        #expect(!command.contains("attach-session"))
    }

    @Test("local attachment stops when kwt cannot start the workspace")
    func localWorktreeStartFailureStopsAttachment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let kwt = directory.appendingPathComponent("kwt")
        let tmux = directory.appendingPathComponent("tmux")
        let tmuxMarker = directory.appendingPathComponent("tmux-ran")
        try """
        #!/bin/sh
        exit 42
        """.write(to: kwt, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        touch "$GHOSTHUB_TMUX_MARKER"
        exit 0
        """.write(to: tmux, atomically: true, encoding: .utf8)
        for executable in [kwt, tmux] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
        }

        let command = TmuxAttachmentInfo(
            sessionName: "kwt-widget-feature",
            host: .local,
            workspacePath: "/worktrees/widget"
        ).attachCommand(
            tmuxPath: tmux.path,
            kwtPath: kwt.path
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GHOSTHUB_TMUX_MARKER": tmuxMarker.path,
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 42)
        #expect(!FileManager.default.fileExists(atPath: tmuxMarker.path))
    }

    @Test("worktree attachment survives destroy-unattached")
    func localWorktreeSurvivesDestroyUnattached() throws {
        let tmuxPath = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { String($0) + "/tmux" }
            .first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
        guard let tmuxPath else {
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let kwt = directory.appendingPathComponent("kwt")
        let config = directory.appendingPathComponent("tmux.conf")
        let marker = directory.appendingPathComponent("session-ran")
        let socketName = "ghosthub-test-\(UUID().uuidString.lowercased())"
        defer {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: tmuxPath)
            cleanup.arguments = ["-L", socketName, "kill-server"]
            cleanup.standardOutput = FileHandle.nullDevice
            cleanup.standardError = FileHandle.nullDevice
            try? cleanup.run()
            cleanup.waitUntilExit()
        }
        try """
        set-option -g destroy-unattached on
        """.write(to: config, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        for argument in "$@"; do
            if [ "$argument" = "--start-session" ]; then
                exec "$GHOSTHUB_TMUX" -L "$GHOSTHUB_TMUX_SOCKET" \
                    -f "$GHOSTHUB_TMUX_CONFIG" new-session -d -s "$GHOSTHUB_TMUX_SESSION" \
                    "sleep 0.2; : > '$GHOSTHUB_SESSION_MARKER'"
            fi
        done
        exec "$GHOSTHUB_TMUX" -L "$GHOSTHUB_TMUX_SOCKET" \
            -f "$GHOSTHUB_TMUX_CONFIG" new-session -A -s "$GHOSTHUB_TMUX_SESSION" \
            "sleep 0.2; : > '$GHOSTHUB_SESSION_MARKER'"
        """.write(to: kwt, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: kwt.path
        )
        let command = TmuxAttachmentInfo(
            sessionName: "kwt-destroy-unattached",
            host: .local,
            workspacePath: "/worktrees/widget"
        ).attachCommand(
            tmuxPath: tmuxPath,
            kwtPath: kwt.path
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GHOSTHUB_TMUX": tmuxPath,
            "GHOSTHUB_TMUX_SOCKET": socketName,
            "GHOSTHUB_TMUX_CONFIG": config.path,
            "GHOSTHUB_TMUX_SESSION": "kwt-destroy-unattached",
            "GHOSTHUB_SESSION_MARKER": marker.path,
            "TERM": "xterm-256color",
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("isolated local attachment targets the returned tmux socket")
    func isolatedLocalAttachCommand() {
        let command = TmuxAttachmentInfo(
            sessionName: "pr-32",
            host: .local,
            socketName: "kwt-pr-0123456789abcdef",
            protectedWorkspacePath: "/worktrees/pr-32"
        ).attachCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            kwtPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        )

        #expect(command.contains(
            "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        ))
        #expect(command.contains("pr"))
        #expect(command.contains("attach"))
        #expect(command.contains("/worktrees/pr-32"))
        #expect(!command.contains("exec '\\''/opt/homebrew/bin/tmux"))
        #expect(
            command.components(
                separatedBy: "kwt-pr-0123456789abcdef"
            ).count - 1 == 3
        )
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

    @Test("isolated remote attachment targets the returned tmux socket")
    func isolatedRemoteAttachCommand() {
        let command = TmuxAttachmentInfo(
            sessionName: "pr-32",
            host: .ssh(SSHHostInfo(
                user: "wesm", hostname: "build-box", port: nil
            )),
            socketName: "kwt-pr-0123456789abcdef",
            protectedWorkspacePath: "/worktrees/pr-32"
        ).attachCommand(
            tmuxPath: "/usr/bin/tmux",
            remoteKwtCommandPrelude:
            "ghosthub_kwt_path=\"$HOME/.ghosthub/helpers/kwt/pinned/kwt\"; "
                + "[ -x \"$ghosthub_kwt_path\" ] || exit 127; "
        )

        #expect(command.contains(
            "$HOME/.ghosthub/helpers/kwt/pinned/kwt"
        ))
        #expect(command.contains("${SHELL:-/bin/sh}"))
        #expect(command.contains("-lc"))
        #expect(command.contains(
            "[ -x \"$ghosthub_kwt_path\" ] || exit 127"
        ))
        #expect(!command.contains("exec ghosthub_kwt_path="))
        #expect(command.contains("pr"))
        #expect(command.contains("attach"))
        #expect(command.contains("/worktrees/pr-32"))
        #expect(!command.contains("exec '\\''/usr/bin/tmux"))
        #expect(command.contains("kwt-pr-0123456789abcdef"))
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

    @Test("local creation atomically attaches under destroy-unattached")
    func localCreationIsAtomic() {
        let info = TmuxAttachmentInfo(
            sessionName: "release-work",
            host: .local,
            launchMode: .create
        )

        let command = info.attachCommand(
            tmuxPath: "/opt/bin/tmux"
        )

        #expect(command.contains("new-session"))
        #expect(command.contains("'-A'"))
        #expect(command.contains("'-E'"))
        #expect(command.contains("release-work"))
        #expect(command.contains("status-style"))
        #expect(!command.contains("'-d'"))
        #expect(!command.contains("attach-session"))
        #expect(
            command.components(separatedBy: "new-session").count == 2
        )
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

    @Test("remote worktree initially attaches through kwt")
    func remoteWorktreeInitiallyAttachesThroughKwt() {
        let command = TmuxAttachmentInfo(
            sessionName: "kwt-widget-feature",
            host: .ssh(SSHHostInfo(
                user: "wesm", hostname: "build-box", port: nil
            )),
            workspacePath: "/srv/widget feature"
        ).attachCommand(
            tmuxPath: "/usr/bin/tmux",
            remoteKwtCommandPrelude:
            "ghosthub_kwt_path=\"$HOME/.ghosthub/helpers/kwt/pinned/kwt\"; "
                + "[ -x \"$ghosthub_kwt_path\" ] || exit 127; "
        )

        #expect(command.contains("'-tt'"))
        #expect(command.contains("/srv/widget feature"))
        #expect(!command.contains("--start-session"))
        #expect(
            command.components(
                separatedBy: "SSH disconnected; reconnecting"
            ).count == 2
        )
    }

    @Test("remote worktree switches to tmux only after transport loss")
    func remoteWorktreeReconnectsAfterTransportLoss() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = directory.appendingPathComponent("initial")
        let reconnect = directory.appendingPathComponent("reconnect")
        try "#!/bin/sh\nexit 255\n".write(
            to: initial, atomically: true, encoding: .utf8
        )
        try """
        #!/bin/sh
        : > "$GHOSTHUB_RECONNECT_MARKER"
        """.write(to: reconnect, atomically: true, encoding: .utf8)
        for executable in [initial, reconnect] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", TmuxAttachmentInfo.remoteWorkspaceAttachScript,
            "ghosthub-test", initial.path, reconnect.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GHOSTHUB_RECONNECT_MARKER": reconnect.path + ".ran",
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(
            atPath: reconnect.path + ".ran"
        ))
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
