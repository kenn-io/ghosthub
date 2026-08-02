import Foundation
import Testing
@testable import GhosthubTmux

@Suite("tmux presentation commands")
struct TmuxPresentationCommandTests {
    @Test("one-shot styling validates and targets the exact selected socket")
    func oneShotCommandTargetsExactSocket() {
        let command = TmuxPresentationCommand(
            sessionName: "review's session",
            socketName: "kwt-pr-0123456789abcdef",
            style: TmuxPresentationStyle(
                foreground: "#DDEEFF",
                background: "#101820"
            )
        ).applyCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            expectedIdentity: TmuxSessionIdentity(
                serverPID: "31415",
                sessionID: "$42",
                createdAt: "1785182057"
            )
        )

        #expect(command.contains("'-L' 'kwt-pr-0123456789abcdef'"))
        #expect(command.contains("'if-shell' '-F' '-t' '=review'\\''s session:'"))
        #expect(command.contains("#{==:#{pid},31415}"))
        #expect(command.contains("#{==:#{session_id},$42}"))
        #expect(command.contains("#{==:#{session_created},1785182057}"))
        #expect(command.contains("$42"))
        #expect(command.contains("status-style"))
        #expect(command.contains("message-style"))
        #expect(command.contains("message-command-style"))
        #expect(command.contains("window-style"))
        #expect(command.contains("window-active-style"))
        #expect(command.contains("fg=#DDEEFF,bg=#101820"))
        #expect(command.contains("'list-windows'"))
    }

    @Test("one-shot and create attachment use the same presentation options")
    func oneShotAndCreateAttachmentStayInParity() {
        let style = TmuxPresentationStyle(
            foreground: "#DDEEFF",
            background: "#101820"
        )
        let oneShot = TmuxPresentationCommand(
            sessionName: "review",
            socketName: nil,
            style: style
        ).applyCommand(
            tmuxPath: "/opt/homebrew/bin/tmux",
            expectedIdentity: TmuxSessionIdentity(
                serverPID: "31415",
                sessionID: "$42",
                createdAt: "1785182057"
            )
        )
        let attachment = TmuxAttachmentInfo(
            sessionName: "review",
            host: .local,
            presentationStyle: style,
            launchMode: .create
        ).attachCommand(tmuxPath: "/opt/homebrew/bin/tmux")

        for option in [
            "status-style",
            "message-style",
            "message-command-style",
            "window-style",
            "window-active-style",
        ] {
            #expect(oneShot.contains(option))
            #expect(attachment.contains(option))
        }
        #expect(oneShot.contains("fg=#DDEEFF,bg=#101820"))
        #expect(attachment.contains("fg=#DDEEFF,bg=#101820"))
    }

    @Test("one-shot styling propagates option failures")
    func oneShotPropagatesOptionFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fakeTmux = directory.appendingPathComponent("tmux")
        try """
        #!/bin/sh
        if [ "$1" = "if-shell" ]; then
          case "$6" in
            *"message-style"*)
              exit 37
              ;;
            *"list-windows"*)
              printf '@1\\n'
              ;;
          esac
          exit 0
        fi
        exit 0
        """.write(to: fakeTmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeTmux.path
        )
        let command = TmuxPresentationCommand(
            sessionName: "review",
            socketName: nil,
            style: TmuxPresentationStyle(
                foreground: "#DDEEFF",
                background: "#101820"
            )
        ).applyCommand(
            tmuxPath: fakeTmux.path,
            expectedIdentity: TmuxSessionIdentity(
                serverPID: "31415",
                sessionID: "$42",
                createdAt: "1785182057"
            )
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 37)
    }

    @Test("every one-shot mutation revalidates the full session identity")
    func oneShotRevalidatesEveryMutation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let invocationLog = directory.appendingPathComponent("invocations")
        let fakeTmux = directory.appendingPathComponent("tmux")
        try """
        #!/bin/sh
        printf '%s\t%s\n' "$1" "$6" >> \(shellQuotedCommandArgument(invocationLog.path))
        if [ "$1" = "if-shell" ]; then
          case "$6" in
            *"display-message -p "*)
              printf 'GHOSTHUB_TMUX_SESSION_IDENTITY_MATCH\\n'
              ;;
            *"list-windows"*)
              printf '@1\\n'
              ;;
          esac
        fi
        exit 0
        """.write(to: fakeTmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeTmux.path
        )
        let command = TmuxPresentationCommand(
            sessionName: "review",
            socketName: nil,
            style: TmuxPresentationStyle(
                foreground: "#DDEEFF",
                background: "#101820"
            )
        ).applyCommand(
            tmuxPath: fakeTmux.path,
            expectedIdentity: TmuxSessionIdentity(
                serverPID: "31415",
                sessionID: "$42",
                createdAt: "1785182057"
            )
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]

        try process.run()
        process.waitUntilExit()

        let invocationText = try String(
            contentsOf: invocationLog,
            encoding: .utf8
        )
        let invocations = invocationText
            .split(separator: "\n")
        #expect(!invocations.isEmpty)
        #expect(invocations.allSatisfy { $0.hasPrefix("if-shell\t") })
        #expect(invocationText.contains("window-active-style"))
    }
}
