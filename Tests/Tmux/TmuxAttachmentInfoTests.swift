import Darwin
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

    @Test("local attachment leaves tmux presentation unchanged by default")
    func localAttachCommandLeavesTmuxPresentationUnchanged() {
        let info = TmuxAttachmentInfo(
            sessionName: "doc bank's work",
            host: .local
        )

        let command = info.attachCommand(
            tmuxPath: "/Applications/My Tools/tmux"
        )

        #expect(command.contains("unset TMUX TMUX_PANE"))
        #expect(!command.contains("set-option"))
        #expect(!command.contains("status-style"))
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
            host: .local,
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
        ).attachCommand(tmuxPath: "/opt/homebrew/bin/tmux")

        #expect(
            command.components(separatedBy: "=alpha:").count - 1 == 4
        )
    }

    @Test("built-in themes set pane defaults for terminal color queries")
    func builtInThemeSetsPaneDefaults() {
        let command = TmuxAttachmentInfo(
            sessionName: "docbank",
            host: .local,
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
        ).attachCommand(tmuxPath: "/opt/homebrew/bin/tmux")

        #expect(command.contains("'list-windows'"))
        #expect(command.contains("'#{window_id}'"))
        #expect(command.contains("\"$ghosthub_window\""))
        #expect(command.contains("'window-style'"))
        #expect(command.contains("'window-active-style'"))
        #expect(command.contains("'status-style'"))
        #expect(command.contains("'message-style'"))
        #expect(command.contains("'message-command-style'"))
        #expect(command.contains("'fg=#3B4851,bg=#FFFFFF'"))
    }

    @Test("follow-config leaves tmux pane defaults unchanged")
    func followConfigLeavesPaneDefaultsUnchanged() {
        let command = TmuxAttachmentInfo(
            sessionName: "docbank",
            host: .local
        ).attachCommand(tmuxPath: "/opt/homebrew/bin/tmux")

        #expect(!command.contains("list-windows"))
        #expect(!command.contains("set-option"))
        #expect(!command.contains("status-style"))
        #expect(!command.contains("window-style"))
        #expect(!command.contains("window-active-style"))
    }

    @Test("protected attachment leads kwt to the resolved tmux")
    func protectedAttachExportsResolvedTmuxDirectory() {
        let command = TmuxAttachmentInfo(
            sessionName: "pr-32",
            host: .local,
            socketName: "kwt-pr-0123456789abcdef",
            protectedWorkspacePath: "/worktrees/pr-32",
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
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
        let kwtPosition = command.range(of: "Helpers/kwt")?.lowerBound
        let stylePosition = command.range(of: "window-style")?.lowerBound
        if let kwtPosition, let stylePosition {
            #expect(kwtPosition < stylePosition)
        }
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

    @Test("existing local worktrees receive built-in theme defaults")
    func localWorktreeReceivesThemeDefaults() {
        let command = TmuxAttachmentInfo(
            sessionName: "kwt-widget-feature",
            host: .local,
            workspacePath: "/worktrees/widget",
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
        ).attachCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            kwtPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        )

        let stylePosition = command.range(of: "window-style")?.lowerBound
        let kwtPosition = command.range(of: "Helpers/kwt")?.lowerBound
        #expect(stylePosition != nil)
        #expect(kwtPosition != nil)
        if let stylePosition, let kwtPosition {
            #expect(kwtPosition < stylePosition)
        }
        #expect(command.contains("#{client_tty}"))
        #expect(command.contains("ghosthub_kwt_tty"))
        #expect(command.contains(
            "while kill -0 \"$ghosthub_kwt_pid\""
        ))
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
        printf '%s\n' "$*" >> "$GHOSTHUB_TMUX_MARKER"
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
            workspacePath: "/worktrees/widget",
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
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
        let tmuxCommands = try String(
            contentsOf: tmuxMarker,
            encoding: .utf8
        )
        #expect(!tmuxCommands.contains("set-option"))
        #expect(!tmuxCommands.contains("attach-session"))
    }

    @Test("theming waits for kwt while another client attaches")
    func themingFollowsKwtSessionRepair() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let kwt = directory.appendingPathComponent("kwt")
        let tmux = directory.appendingPathComponent("tmux")
        let log = directory.appendingPathComponent("tmux.log")
        let clientTTY = directory.appendingPathComponent("client.tty")
        let unrelatedClient = directory.appendingPathComponent(
            "unrelated-client"
        )
        try """
        #!/bin/sh
        "$GHOSTHUB_TMUX" new-session
        "$GHOSTHUB_TMUX" new-window
        /bin/sh -c '"$GHOSTHUB_TMUX" attach-session'
        """.write(to: kwt, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        case " $* " in
          *" new-session "*)
            : > "$GHOSTHUB_TMUX_UNRELATED_CLIENT"
            sleep 0.05
            printf 'new-session\n' >> "$GHOSTHUB_TMUX_LOG"
            ;;
          *" new-window "*)
            printf 'new-window\n' >> "$GHOSTHUB_TMUX_LOG"
            ;;
          *" attach-session "*)
            tty > "$GHOSTHUB_TMUX_CLIENT_TTY"
            trap 'rm -f "$GHOSTHUB_TMUX_CLIENT_TTY"' EXIT
            ghosthub_waits=0
            while ! grep -q '@2 window-active-style' \
                "$GHOSTHUB_TMUX_LOG"; do
              ghosthub_waits=$((ghosthub_waits + 1))
              [ "$ghosthub_waits" -ge 100 ] && break
              sleep 0.01
            done
            ;;
          *" list-clients "*)
            if [ -f "$GHOSTHUB_TMUX_UNRELATED_CLIENT" ]; then
              printf '/dev/unrelated\n'
            fi
            if [ -f "$GHOSTHUB_TMUX_CLIENT_TTY" ]; then
              cat "$GHOSTHUB_TMUX_CLIENT_TTY"
            fi
            ;;
          *" list-windows "*)
            if ! grep -q new-window "$GHOSTHUB_TMUX_LOG"; then
              printf 'early-list-windows\n' >> "$GHOSTHUB_TMUX_LOG"
              exit 1
            fi
            printf '@1\n@2\n'
            ;;
          *" set-option "*)
            if ! grep -q new-window "$GHOSTHUB_TMUX_LOG"; then
              printf 'early-set-option\n' >> "$GHOSTHUB_TMUX_LOG"
              exit 1
            fi
            printf 'set-option %s\n' "$*" >> "$GHOSTHUB_TMUX_LOG"
            ;;
        esac
        """.write(to: tmux, atomically: true, encoding: .utf8)
        for executable in [kwt, tmux] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
        }

        let command = TmuxAttachmentInfo(
            sessionName: "kwt-widget-feature",
            host: .local,
            workspacePath: "/worktrees/widget",
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
        ).attachCommand(
            tmuxPath: tmux.path,
            kwtPath: kwt.path
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GHOSTHUB_TMUX": tmux.path,
            "GHOSTHUB_TMUX_LOG": log.path,
            "GHOSTHUB_TMUX_CLIENT_TTY": clientTTY.path,
            "GHOSTHUB_TMUX_UNRELATED_CLIENT": unrelatedClient.path,
            "TERM": "xterm-256color",
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let tmuxCommands = try String(contentsOf: log, encoding: .utf8)
        #expect(!tmuxCommands.contains("early-"))
        #expect(tmuxCommands.contains("@1 window-style"))
        #expect(tmuxCommands.contains("@2 window-active-style"))
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
        let socketName = ProcessInfo.processInfo.environment[
            "GHOSTHUB_TEST_TMUX_RUN_ID"
        ].map { "ghosthub-test-\($0)" }
            ?? "ghosthub-test-\(UUID().uuidString.lowercased())"
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
        "$GHOSTHUB_TMUX" -L "$GHOSTHUB_TMUX_SOCKET" \
            -f "$GHOSTHUB_TMUX_CONFIG" new-session -A -s "$GHOSTHUB_TMUX_SESSION" \
            "sleep 0.2; : > '$GHOSTHUB_SESSION_MARKER'"
        """.write(to: kwt, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: kwt.path
        )
        let command = TmuxAttachmentInfo(
            sessionName: "kwt-destroy-unattached",
            host: .local,
            workspacePath: "/worktrees/widget",
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
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
            protectedWorkspacePath: "/worktrees/pr-32",
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
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
        #expect(command.contains(
            "'\\''-L'\\'' '\\''kwt-pr-0123456789abcdef'\\''"
        ))
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

        #expect(command.contains("/usr/bin/ssh"))
        #expect(command.contains("-tt"))
        #expect(command.contains("${SHELL:-/bin/sh}"))
        #expect(command.contains(" -lc "))
        #expect(command.contains("'ServerAliveInterval=15'"))
        #expect(command.contains("'ServerAliveCountMax=3'"))
        #expect(command.contains("'TCPKeepAlive=yes'"))
        #expect(command.contains("'wesm@build-box'"))
        #expect(command.contains("'attach-session'"))
        #expect(command.contains("'-E'"))
        #expect(command.contains("=docbank"))
        #expect(!command.contains("status-style"))
        #expect(!command.contains("message-style"))
        #expect(!command.contains("message-command-style"))
        #expect(!command.contains("-CC"))
        #expect(!command.contains("KexAlgorithms"))
        #expect(!command.contains("bind-key"))
        #expect(!command.contains("unbind-key"))
    }

    @Test("Windows attachment leaves psmux presentation user-owned")
    func windowsRemoteAttachCommand() throws {
        let command = TmuxAttachmentInfo(
            sessionName: "doc bank's work",
            host: .ssh(SSHHostInfo(
                user: "wesm",
                hostname: "arm-builder",
                port: 2222,
                platform: .windows
            ))
        ).attachCommand(
            tmuxPath: #"C:\Program Files\psmux\tmux.exe"#,
            windowsKwtRelativePath:
            #".ghosthub\helpers\kwt\0123456789012345678901234567890123456789\kwt.exe"#
        )

        #expect(command.contains("/usr/bin/ssh"))
        #expect(command.contains("-tt"))
        #expect(command.contains("'wesm@arm-builder'"))
        #expect(command.contains("-EncodedCommand"))
        #expect(command.contains("ghosthub-ssh-psmux"))
        #expect(!command.contains("command -v"))

        let script = try Self.decodedPowerShellScript(from: command)
        #expect(script.contains(
            "& " + [
                #"C:\Program Files\psmux\tmux.exe"#,
                "attach-session",
                "-E",
                "-t",
                "=doc bank's work",
            ]
            .map(powerShellEncodedArgument)
            .joined(separator: " ")
        ))
    }

    @Test("Windows attachment keeps hostile values out of PowerShell source")
    func windowsRemoteAttachEncodesHostileSessionName() throws {
        let sessionName = #"x’;iex("attacker-command");#‘&|$()"#
        let command = TmuxAttachmentInfo(
            sessionName: sessionName,
            host: .ssh(SSHHostInfo(
                user: "wesm",
                hostname: "arm-builder",
                port: nil,
                platform: .windows
            ))
        ).attachCommand(tmuxPath: #"C:\Tools\psmux\tmux.exe"#)

        let script = try Self.decodedPowerShellScript(from: command)
        #expect(script.contains(
            powerShellEncodedArgument("=\(sessionName)")
        ))
        #expect(!script.contains(sessionName))
        #expect(!script.contains("iex("))
        #expect(!script.contains("’"))
        #expect(!script.contains("‘"))
    }

    @Test("Windows worktrees open through kwt before psmux reconnect")
    func windowsRemoteWorkspaceAttachCommand() throws {
        let command = TmuxAttachmentInfo(
            sessionName: "release work",
            host: .ssh(SSHHostInfo(
                user: "wesm",
                hostname: "arm-builder",
                port: nil,
                platform: .windows
            )),
            workspacePath: #"C:\code\release work"#
        ).attachCommand(
            tmuxPath: #"C:\Program Files\psmux\tmux.exe"#,
            windowsKwtRelativePath:
            #".ghosthub\helpers\kwt\0123456789012345678901234567890123456789\kwt.exe"#
        )

        #expect(command.contains("ghosthub-ssh-kwt-attach"))
        #expect(command.contains("ghosthub-ssh-kwt-probe"))
        let decoded = try Self.decodedPowerShellScripts(from: command)
        let scripts = try #require(decoded.count == 3 ? decoded : nil)
        #expect(scripts[0].contains(
            powerShellEncodedArgument(
                #".ghosthub\helpers\kwt\0123456789012345678901234567890123456789\kwt.exe"#
            )
        ))
        #expect(!scripts[0].contains("Get-Command kwt.exe"))
        #expect(scripts[0].contains(
            "& $ghosthubKwt 'open' "
                + powerShellEncodedArgument(#"C:\code\release work"#)
        ))
        #expect(scripts[1].contains(
            "& " + [
                #"C:\Program Files\psmux\tmux.exe"#,
                "has-session",
                "-t",
                "=release work",
            ]
            .map(powerShellEncodedArgument)
            .joined(separator: " ")
        ))
        #expect(scripts[2].contains(
            "& " + [
                #"C:\Program Files\psmux\tmux.exe"#,
                "attach-session",
                "-E",
                "-t",
                "=release work",
            ]
            .map(powerShellEncodedArgument)
            .joined(separator: " ")
        ))
        #expect(!scripts.joined().contains("exec /bin/sh"))
    }

    @Test("isolated remote attachment targets the returned tmux socket")
    func isolatedRemoteAttachCommand() {
        let command = TmuxAttachmentInfo(
            sessionName: "pr-32",
            host: .ssh(SSHHostInfo(
                user: "wesm", hostname: "build-box", port: nil
            )),
            socketName: "kwt-pr-0123456789abcdef",
            protectedWorkspacePath: "/worktrees/pr-32",
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
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
        #expect(command.contains("ghosthub_kwt_path"))
        #expect(command.contains("exit 127"))
        #expect(!command.contains("exec ghosthub_kwt_path="))
        #expect(command.contains("pr"))
        #expect(command.contains("attach"))
        #expect(command.contains("/worktrees/pr-32"))
        #expect(!command.contains("exec '\\''/usr/bin/tmux"))
        #expect(command.contains("kwt-pr-0123456789abcdef"))
        let kwtPosition = command.range(of: "ghosthub_kwt_path")?.lowerBound
        let stylePosition = command.range(of: "window-style")?.lowerBound
        if let kwtPosition, let stylePosition {
            #expect(kwtPosition < stylePosition)
        }
    }

    @Test("normal SSH arguments preserve OpenSSH connection sharing")
    func normalSSHArgumentsPreserveOpenSSHConnectionSharing() {
        let arguments = tmuxSSHConnectionArguments(environment: [:])

        #expect(!arguments.contains("ControlMaster=no"))
        #expect(!arguments.contains("ControlPath=none"))
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

        #expect(command.contains("/tmp/ghosthub demo/ssh/config"))
        #expect(command.contains(
            "UserKnownHostsFile=/tmp/ghosthub demo/ssh/known_hosts"
        ))
        #expect(command.contains("GlobalKnownHostsFile=/dev/null"))
        #expect(command.contains("StrictHostKeyChecking=yes"))
        #expect(command.contains("ProxyCommand=none"))
        #expect(command.contains("ProxyJump=none"))
        #expect(command.contains("ControlMaster=no"))
        #expect(command.contains("ControlPath=none"))
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
        #expect(!command.contains("status-style"))
        #expect(!command.contains("'-d'"))
        #expect(!command.contains("attach-session"))
        #expect(
            command.components(separatedBy: "new-session").count == 2
        )
    }

    @Test("remote creation presents before its reconnect loop")
    func remoteCreationPresentsBeforeReconnectLoop() {
        let info = TmuxAttachmentInfo(
            sessionName: "release-work",
            host: .ssh(SSHHostInfo(
                user: "wesm", hostname: "build-box", port: nil
            )),
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            ),
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
        let presentationPosition = command.range(
            of: "while IFS= read -r ghosthub_window"
        )?.lowerBound
        let reconnectPosition = command.range(
            of: "SSH disconnected; reconnecting"
        )?.lowerBound
        #expect(presentationPosition != nil)
        #expect(reconnectPosition != nil)
        #expect(
            command.components(
                separatedBy: "while IFS= read -r ghosthub_window"
            ).count - 1 == 1
        )
        if let presentationPosition, let reconnectPosition {
            #expect(presentationPosition < reconnectPosition)
        }
        // The escape depth of "$?" varies with the surrounding quoting
        // layers, so match any depth rather than a hardcoded count.
        let creationGuardPosition = command.range(
            of: #"\|\| exit \\+\$\?"#,
            options: .regularExpression
        )?.lowerBound
        #expect(creationGuardPosition != nil)
        if let creationGuardPosition, let presentationPosition {
            #expect(creationGuardPosition < presentationPosition)
        }
        #expect(command.contains("; done; exit 0"))
        // Creation styles through the account login shell, so attachment must
        // resolve the same login environment (TMUX_TMPDIR) and tmux server:
        // one login handoff each for the outer command, the create phase, and
        // the attach phase.
        #expect(
            command.components(
                separatedBy: "${SHELL:-/bin/sh}"
            ).count - 1 == 3
        )
    }

    @Test("unstyled remote creation still runs through the login shell")
    func unstyledRemoteCreationUsesLoginShell() {
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
        #expect(!command.contains("window-style"))
        // Deferred styling and identity checks later run through the account
        // login shell, so creation and attachment must resolve the same login
        // environment (TMUX_TMPDIR) even before any style exists: one login
        // handoff each for the outer command, the create phase, and the
        // attach phase.
        #expect(
            command.components(
                separatedBy: "${SHELL:-/bin/sh}"
            ).count - 1 == 3
        )
    }

    @Test("unstyled remote attachment still runs through the login shell")
    func unstyledRemoteAttachmentUsesLoginShell() {
        let command = TmuxAttachmentInfo(
            sessionName: "docbank",
            host: .ssh(SSHHostInfo(
                user: "wesm", hostname: "build-box", port: nil
            ))
        ).attachCommand(tmuxPath: "/opt/bin/tmux")

        #expect(command.contains("attach-session"))
        #expect(!command.contains("window-style"))
        // One login handoff for the outer command, one for the remote attach.
        #expect(
            command.components(
                separatedBy: "${SHELL:-/bin/sh}"
            ).count - 1 == 2
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
        #expect(command.contains("ghosthub-ssh-kwt-probe"))
        #expect(command.contains("has-session"))
        #expect(
            command.components(
                separatedBy: "${SHELL:-/bin/sh}"
            ).count - 1 == 4
        )
    }

    @Test("existing remote worktrees receive built-in theme defaults")
    func remoteWorktreeReceivesThemeDefaults() {
        let command = TmuxAttachmentInfo(
            sessionName: "kwt-widget-feature",
            host: .ssh(SSHHostInfo(
                user: "wesm", hostname: "build-box", port: nil
            )),
            workspacePath: "/srv/widget",
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
        ).attachCommand(
            tmuxPath: "/usr/bin/tmux",
            remoteKwtCommandPrelude:
            "ghosthub_kwt_path=\"$HOME/.ghosthub/helpers/kwt/pinned/kwt\"; "
                + "[ -x \"$ghosthub_kwt_path\" ] || exit 127; "
        )

        #expect(command.contains("list-windows"))
        #expect(command.contains("window-style"))
        #expect(command.contains("fg=#3B4851,bg=#FFFFFF"))
        let kwtPosition = command.range(of: "ghosthub_kwt_path")?.lowerBound
        let stylePosition = command.range(of: "window-style")?.lowerBound
        if let kwtPosition, let stylePosition {
            #expect(kwtPosition < stylePosition)
        }
    }

    @Test("themed remote attachment supports non-POSIX account shells")
    func themedRemoteAttachmentUsesPOSIXShell() {
        let command = TmuxAttachmentInfo(
            sessionName: "shared-session",
            host: .ssh(SSHHostInfo(
                user: "wesm", hostname: "build-box", port: nil
            )),
            presentationStyle: TmuxPresentationStyle(
                foreground: "#3B4851",
                background: "#FFFFFF"
            )
        ).attachCommand(tmuxPath: "/usr/bin/tmux")

        #expect(command.contains("${SHELL:-/bin/sh}"))
        let loginShellPosition = command.range(
            of: "${SHELL:-/bin/sh}"
        )?.lowerBound
        let presentationPosition = command.range(
            of: "while IFS= read -r ghosthub_window"
        )?.lowerBound
        #expect(loginShellPosition != nil)
        #expect(presentationPosition != nil)
        if let loginShellPosition, let presentationPosition {
            #expect(loginShellPosition < presentationPosition)
        }
    }

    @Test("account login handoff survives libghostty's macOS exec wrapper")
    func accountLoginHandoffSurvivesLibghosttyExecWrapper() throws {
        let password = try #require(getpwuid(getuid()))
        let shell = String(cString: password.pointee.pw_shell)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "--noprofile", "--norc", "-c",
            "exec -l " + surfaceAccountLoginShellCommand(
                "printf 'GHOSTHUB_ACCOUNT_SHELL_READY\\n'"
            ),
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "SHELL": shell,
        ]) { _, new in new }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        #expect(process.terminationStatus == 0)
        #expect(text == "GHOSTHUB_ACCOUNT_SHELL_READY\n")
    }

    @Test("remote attachment keeps POSIX source opaque to the account shell")
    func remoteAttachmentDelegatesPOSIXSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("account-shell-ready")
        let shell = directory.appendingPathComponent("account-shell")
        try """
        #!/bin/sh
        set -eu
        [ "$1" = "-lc" ] || exit 96
        case "$2" in
          'exec /bin/sh -c "'*'"') ;;
          *) exit 97 ;;
        esac
        : > "$GHOSTHUB_ACCOUNT_SHELL_MARKER"
        exec /bin/sh -c "$2"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let command = TmuxAttachmentInfo(
            sessionName: "fixture-session",
            host: .ssh(SSHHostInfo(
                user: "test-user",
                hostname: "test-host.invalid",
                port: nil
            ))
        ).attachCommand(
            tmuxPath: "/usr/bin/true",
            sshConnectionArguments: ["-V"]
        )
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "--noprofile", "--norc", "-c",
            "exec -l " + command,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GHOSTHUB_ACCOUNT_SHELL_MARKER": marker.path,
            "SHELL": shell.path,
        ]) { _, new in new }
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        #expect(
            process.terminationStatus == 0,
            Comment(rawValue: text)
        )
        #expect(FileManager.default.fileExists(atPath: marker.path))
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
        let probe = directory.appendingPathComponent("probe")
        let reconnect = directory.appendingPathComponent("reconnect")
        try "#!/bin/sh\nexit 255\n".write(
            to: initial, atomically: true, encoding: .utf8
        )
        try "#!/bin/sh\nexit 0\n".write(
            to: probe, atomically: true, encoding: .utf8
        )
        try """
        #!/bin/sh
        : > "$GHOSTHUB_RECONNECT_MARKER"
        """.write(to: reconnect, atomically: true, encoding: .utf8)
        for executable in [initial, probe, reconnect] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", TmuxAttachmentInfo.remoteWorkspaceAttachScript,
            "ghosthub-test", initial.path, probe.path, reconnect.path,
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

    @Test("remote worktree retries kwt when transport fails before creation")
    func remoteWorktreeRetriesKwtWhenSessionIsAbsent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialCounter = directory.appendingPathComponent("initial-count")
        let sleepCounter = directory.appendingPathComponent("sleep-count")
        let initial = directory.appendingPathComponent("initial")
        let probe = directory.appendingPathComponent("probe")
        let reconnect = directory.appendingPathComponent("reconnect")
        let sleep = directory.appendingPathComponent("sleep")
        try """
        #!/bin/sh
        printf x >> "$GHOSTHUB_INITIAL_COUNTER"
        [ "$(wc -c < "$GHOSTHUB_INITIAL_COUNTER")" -gt 1 ] && exit 0
        exit 255
        """.write(to: initial, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 1\n".write(
            to: probe, atomically: true, encoding: .utf8
        )
        try """
        #!/bin/sh
        : > "$GHOSTHUB_RECONNECT_MARKER"
        """.write(to: reconnect, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        printf '%s\n' "$1" >> "$GHOSTHUB_SLEEP_COUNTER"
        """.write(to: sleep, atomically: true, encoding: .utf8)
        for executable in [initial, probe, reconnect, sleep] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", TmuxAttachmentInfo.remoteWorkspaceAttachScript,
            "ghosthub-test", initial.path, probe.path, reconnect.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GHOSTHUB_INITIAL_COUNTER": initialCounter.path,
            "GHOSTHUB_RECONNECT_MARKER": reconnect.path + ".ran",
            "GHOSTHUB_SLEEP_COUNTER": sleepCounter.path,
            "PATH": directory.path + ":"
                + ProcessInfo.processInfo.environment["PATH", default: ""],
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(
            try String(contentsOf: initialCounter, encoding: .utf8) == "xx"
        )
        #expect(
            try String(contentsOf: sleepCounter, encoding: .utf8) == "1\n"
        )
        #expect(!FileManager.default.fileExists(
            atPath: reconnect.path + ".ran"
        ))
    }

    @Test("Windows named creation runs once before psmux attachment")
    func windowsRemoteCreationIsOneShot() throws {
        let command = TmuxAttachmentInfo(
            sessionName: "release-work",
            host: .ssh(SSHHostInfo(
                user: "wesm",
                hostname: "arm-builder",
                port: nil,
                platform: .windows
            )),
            launchMode: .create
        ).attachCommand(
            tmuxPath: #"C:\Tools\psmux\tmux.exe"#,
            workingDirectory: #"C:\code\release work"#
        )

        #expect(command.contains("'-T'"))
        #expect(command.contains("'-tt'"))
        #expect(
            command.components(separatedBy: "-EncodedCommand").count == 3
        )
        let decoded = try Self.decodedPowerShellScripts(from: command)
        let scripts = try #require(decoded.count == 2 ? decoded : nil)
        #expect(scripts[0].contains(
            "& " + [
                #"C:\Tools\psmux\tmux.exe"#,
                "has-session",
                "-t",
                "=release-work",
            ]
            .map(powerShellEncodedArgument)
            .joined(separator: " ")
        ))
        #expect(scripts[0].contains(
            [
                "new-session",
                "-d",
                "-E",
                "-s",
                "release-work",
                "-c",
                #"C:\code\release work"#,
            ]
            .map(powerShellEncodedArgument)
            .joined(separator: " ")
            + " '-e' ('PATH=' + $env:PATH)"
        ))
        #expect(scripts[1].contains(
            ["attach-session", "-E", "-t", "=release-work"]
                .map(powerShellEncodedArgument)
                .joined(separator: " ")
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

    private static func decodedPowerShellScript(
        from command: String
    ) throws -> String {
        try #require(decodedPowerShellScripts(from: command).first)
    }

    private static func decodedPowerShellScripts(
        from command: String
    ) throws -> [String] {
        let marker = "-EncodedCommand "
        return try command
            .components(separatedBy: marker)
            .dropFirst()
            .map { suffix in
                let encoded = try #require(suffix.split(separator: "'").first)
                let data = try #require(Data(base64Encoded: String(encoded)))
                return try #require(String(
                    data: data,
                    encoding: .utf16LittleEndian
                ))
            }
    }
}
