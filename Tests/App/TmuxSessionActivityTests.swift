import Combine
import Foundation
import GhosthubTransport
import GhosthubTmux
import GhosthubUI
import Testing
@testable import GhosthubApp

private let activityIdentity = TmuxSessionIdentity(
    serverPID: "1234",
    sessionID: "$7",
    createdAt: "1720000000"
)

@Suite("Tmux session activity probe")
struct TmuxSessionActivityProbeTests {
    @Test("samples only the exact selected session")
    func exactSessionCommand() {
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "review session",
            socketName: "private socket"
        )

        let command = TmuxSessionActivityProbe.command(
            tmuxPath: "/opt/homebrew/bin/tmux",
            selection: selection,
            expectedIdentity: activityIdentity
        )

        #expect(command.contains("capture-pane"))
        #expect(command.contains("-S -160"))
        #expect(command.contains("'private socket'"))
        #expect(command.contains("'=review session:'"))
        #expect(command.contains("if-shell -F"))
        #expect(command.contains("#{==:#{pid},1234}"))
        #expect(command.contains("GHOSTHUB_TMUX_ACTIVITY_ENDED"))
        #expect(!command.contains("list-sessions"))
    }

    @Test("Windows probes hash the bounded capture on the host")
    func windowsCommand() {
        let command = TmuxSessionActivityProbe.command(
            tmuxPath: "C:\\Program Files\\tmux\\tmux.exe",
            selection: WorkspaceTmuxSessionSelection(
                hostID: UUID(),
                name: "review"
            ),
            expectedIdentity: activityIdentity,
            platform: .windows
        )

        #expect(command.contains("System.Security.Cryptography.SHA256"))
        #expect(command.contains("ghosthubActivityCapture"))
        #expect(command.contains("ghosthubActivityVersion"))
        #expect(command.contains("3.3.4"))
        #expect(command.contains("GHOSTHUB_TMUX_ACTIVITY_SUPPORTED"))
        #expect(command.contains("ghosthubActivityFormatProbe"))
        #expect(command.contains("ghosthubActivityIfShellProbe"))
        #expect(command.contains("$ghosthubActivityPane"))
        #expect(command.contains("GHOSTHUB_TMUX_ACTIVITY_MISMATCH"))
        #expect(command.contains("GHOSTHUB_TMUX_ACTIVITY_ENDED"))
        #expect(!command.contains("cksum"))
    }

    @Test("accepts a checksum only between matching identity reads")
    func parsesIdentityFencedSample() {
        let output = """
        noisy shell startup
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x30\t3
        GHOSTHUB_TMUX_ACTIVITY_CHECKSUM\t8f41a2\t412\t161
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x30\t3
        """

        #expect(
            TmuxSessionActivityProbe.parse(
                output,
                expectedIdentity: activityIdentity
            ) == .sample(
                paneID: "%2",
                dimensions: "120x30",
                fingerprint: "8f41a2:412:161",
                windowCount: 3
            )
        )
    }

    @Test("keeps activity when the window count changes during a sample")
    func changingWindowCountIsNotPublished() {
        let output = """
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x30\t2
        GHOSTHUB_TMUX_ACTIVITY_CHECKSUM\t8f41a2\t412\t161
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x30\t3
        """

        #expect(
            TmuxSessionActivityProbe.parse(
                output,
                expectedIdentity: activityIdentity
            ) == .sample(
                paneID: "%2",
                dimensions: "120x30",
                fingerprint: "8f41a2:412:161"
            )
        )
    }

    @Test("ends tracking when the exact session identity changes")
    func rejectsReplacementSession() {
        let output = """
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x30
        GHOSTHUB_TMUX_ACTIVITY_CHECKSUM\t9981\t412\t161
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$8\t1720000010\t%3\t120x30
        """

        #expect(
            TmuxSessionActivityProbe.parse(
                output,
                expectedIdentity: activityIdentity
            ) == .ended
        )
    }

    @Test("rejects a sample spanning an active pane switch")
    func rejectsPaneSwitchDuringSample() {
        let output = """
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x30
        GHOSTHUB_TMUX_ACTIVITY_CHECKSUM\t9981\t412\t161
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%3\t120x30
        """

        #expect(
            TmuxSessionActivityProbe.parse(
                output,
                expectedIdentity: activityIdentity
            ) == .unavailable
        )
    }

    @Test("rejects a sample spanning a pane resize")
    func rejectsPaneResizeDuringSample() {
        let output = """
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x30
        GHOSTHUB_TMUX_ACTIVITY_CHECKSUM\t9981\t412\t161
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t80x30
        """

        #expect(
            TmuxSessionActivityProbe.parse(
                output,
                expectedIdentity: activityIdentity
            ) == .unavailable
        )
    }

    @Test("rejects malformed pane dimensions")
    func rejectsMalformedDimensions() {
        let output = """
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x
        GHOSTHUB_TMUX_ACTIVITY_CHECKSUM\t9981\t412\t161
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x
        """

        #expect(
            TmuxSessionActivityProbe.parse(
                output,
                expectedIdentity: activityIdentity
            ) == .unavailable
        )
    }

    @Test("rejects checksum metadata outside the identity fence")
    func rejectsUnfencedChecksum() {
        let output = """
        GHOSTHUB_TMUX_ACTIVITY_CHECKSUM\t9981\t412\t161
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x30
        GHOSTHUB_TMUX_ACTIVITY_IDENTITY\t1234\t$7\t1720000000\t%2\t120x30
        """

        #expect(
            TmuxSessionActivityProbe.parse(
                output,
                expectedIdentity: activityIdentity
            ) == .unavailable
        )
    }

    @Test("treats an unmarked status one as unavailable")
    func genericStatusOneIsUnavailable() async {
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in (status: 1, stdout: "") }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )

        let result = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )

        #expect(result == .unavailable)
    }

    @Test("ends tracking only for an explicit absence marker")
    func explicitAbsenceEndsTracking() async {
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in .success("/usr/bin/tmux") },
            runner: { _, _ in
                (
                    status: 0,
                    stdout: "GHOSTHUB_TMUX_ACTIVITY_ENDED\n"
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )

        let result = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )

        #expect(result == .ended)
    }

    @Test(
        "only confirmed absence diagnostics emit an ended probe",
        arguments: [
            (
                "can't find session: build",
                TmuxSessionActivityProbeResult.ended
            ),
            (
                "no server running on /private/tmp/tmux-501/default",
                TmuxSessionActivityProbeResult.ended
            ),
            (
                "error connecting to /private/tmp/tmux-501/default "
                    + "(No such file or directory)",
                TmuxSessionActivityProbeResult.ended
            ),
            (
                "failed to connect to server: No such file or directory",
                TmuxSessionActivityProbeResult.ended
            ),
            (
                "error connecting to socket (Permission denied)",
                TmuxSessionActivityProbeResult.unavailable
            ),
            (
                "error connecting to /private/tmp/tmux-501/default "
                    + "(Socket operation on non-socket)",
                TmuxSessionActivityProbeResult.unavailable
            ),
        ]
    )
    func confirmsAbsenceBeforeEnding(
        diagnostic: String,
        expected: TmuxSessionActivityProbeResult
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = directory.appendingPathComponent("tmux")
        try """
        #!/bin/sh
        printf '%s\\n' \(shellQuotedCommandArgument(diagnostic)) >&2
        exit 1
        """.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmux.path
        )
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in .success(tmux.path) },
            runner: { _, command in
                AccountCommandRunner.runLoginShell(
                    shell: "/bin/sh",
                    command: command,
                    timeout: 10
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )

        let result = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )

        #expect(result == expected)
    }

    @Test("a same-named replacement session is never captured")
    func replacementSessionIsNotCaptured() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = directory.appendingPathComponent("tmux")
        let counter = directory.appendingPathComponent("capture-count")
        try """
        #!/bin/sh
        case " $* " in
            *" display-message "*"GHOSTHUB_TMUX_ACTIVITY_IDENTITY"*)
                printf 'GHOSTHUB_TMUX_ACTIVITY_IDENTITY\\t9999\\t$8\\t1720000099\\t%%2\\t120x30\\n'
                ;;
            *" display-message "*)
                printf '5\\n'
                ;;
            *" capture-pane "*)
                printf '1\\n' > \(shellQuotedCommandArgument(counter.path))
                printf 'replacement scrollback\\n'
                ;;
        esac
        """.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmux.path
        )
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in .success(tmux.path) },
            runner: { _, command in
                AccountCommandRunner.runLoginShell(
                    shell: "/bin/sh",
                    command: command,
                    timeout: 10
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )

        let result = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )

        #expect(result == .ended)
        #expect(!FileManager.default.fileExists(atPath: counter.path))
    }

    @Test("a replacement racing the verified identity read is not captured")
    func replacementAfterIdentityReadIsNotCaptured() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = directory.appendingPathComponent("tmux")
        let leak = directory.appendingPathComponent("captured-leak")
        try statefulFakeTmux(
            directory: directory,
            replacesAfterFirstIdentityRead: true,
            capture: "printf 'replacement scrollback\\n'"
        ).write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmux.path
        )
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in .success(tmux.path) },
            runner: { _, command in
                AccountCommandRunner.runLoginShell(
                    shell: "/bin/sh",
                    command: command,
                    timeout: 10
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )

        let result = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )

        #expect(result == .ended)
        #expect(!FileManager.default.fileExists(atPath: leak.path))
    }

    @Test("live scrollback resembling probe markers stays a valid sample")
    func markerLookalikeContentIsNotReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = directory.appendingPathComponent("tmux")
        try statefulFakeTmux(
            directory: directory,
            replacesAfterFirstIdentityRead: false,
            capture: "printf 'GHOSTHUB_TMUX_ACTIVITY_MISMATCH is discussed here\\n'"
        ).write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmux.path
        )
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in .success(tmux.path) },
            runner: { _, command in
                AccountCommandRunner.runLoginShell(
                    shell: "/bin/sh",
                    command: command,
                    timeout: 10
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )

        let result = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )

        guard case .sample = result else {
            Issue.record("expected a valid sample, got \(result)")
            return
        }
    }

    @Test("a cancelled sample never contacts the host")
    func cancelledSampleSkipsRunner() async {
        let resolverEntered = LockedFlag()
        let resolverGate = DispatchSemaphore(value: 0)
        let runnerInvoked = LockedFlag()
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in
                resolverEntered.set()
                resolverGate.wait()
                return .success("/usr/bin/tmux")
            },
            runner: { _, _ in
                runnerInvoked.set()
                return (status: 0, stdout: "")
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )

        let sample = Task {
            await probe.sample(
                selection,
                expectedIdentity: activityIdentity,
                on: .local
            )
        }
        while !resolverEntered.isSet {
            await Task.yield()
        }
        sample.cancel()
        resolverGate.signal()
        let result = await sample.value

        #expect(result == .unavailable)
        #expect(!runnerInvoked.isSet)
    }

    @Test("tmux resolution invalidates a dead pooled connection")
    func resolverInvalidatesDeadConnection() async {
        let invalidations = LockedValue(0)
        let classification = SSHConnectionFailure.classify(
            status: 255,
            output: "Control socket connect(/tmp/dead.sock): No such file or directory"
        )
        let host = CommandHost.ssh(SSHHostInfo(
            user: nil,
            hostname: "builder.example.test",
            port: nil
        ))
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in
                .failure(.sshConnectionFailed(
                    host: host.displayName,
                    classification: classification
                ))
            },
            runner: { _, _ in (0, "") },
            commandLease: KwtSSHCommandLease { _ in
                KwtSSHConnection(
                    arguments: ["-S", "/tmp/dead.sock"],
                    routeIdentity: "reviewed-route",
                    generation: 1,
                    invalidate: { invalidations.withLock { $0 += 1 } }
                )
            }
        )

        #expect(await probe.sample(
            WorkspaceTmuxSessionSelection(hostID: UUID(), name: "review"),
            expectedIdentity: activityIdentity,
            on: host
        ) == .unavailable)
        #expect(invalidations.load() == 1)
    }

    @Test("visible pane redraws do not change activity samples")
    func ignoresVisiblePaneRedraws() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = directory.appendingPathComponent("tmux")
        let counter = directory.appendingPathComponent("capture-count")
        try """
        #!/bin/sh
        case " $* " in
            *" display-message "*"GHOSTHUB_TMUX_ACTIVITY_IDENTITY"*)
                printf 'GHOSTHUB_TMUX_ACTIVITY_IDENTITY\\t1234\\t$7\\t1720000000\\t%%2\\t120x30\\n'
                ;;
            *" display-message "*)
                printf '0\\n'
                ;;
            *" capture-pane "*)
                count=0
                if [ -f \(shellQuotedCommandArgument(counter.path)) ]; then
                    count=$(cat \(shellQuotedCommandArgument(counter.path)))
                fi
                count=$((count + 1))
                printf '%s\\n' "$count" > \(shellQuotedCommandArgument(counter.path))
                printf 'visible redraw %s\\n' "$count"
                ;;
        esac
        """.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmux.path
        )
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in .success(tmux.path) },
            runner: { _, command in
                AccountCommandRunner.runLoginShell(
                    shell: "/bin/sh",
                    command: command,
                    timeout: 10
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )

        let first = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )
        let second = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )

        let emptyCapture = TmuxSessionActivityProbeResult.sample(
            paneID: "%2",
            dimensions: "120x30",
            fingerprint: "4294967295:0:0"
        )
        #expect(first == emptyCapture)
        #expect(second == emptyCapture)
        #expect(!FileManager.default.fileExists(atPath: counter.path))
    }

    @Test("trailing blank output changes the activity fingerprint")
    func preservesTrailingBlankOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = directory.appendingPathComponent("tmux")
        let counter = directory.appendingPathComponent("capture-count")
        try """
        #!/bin/sh
        case " $* " in
            *" display-message "*"GHOSTHUB_TMUX_ACTIVITY_IDENTITY"*)
                printf 'GHOSTHUB_TMUX_ACTIVITY_IDENTITY\\t1234\\t$7\\t1720000000\\t%%2\\t120x30\\n'
                ;;
            *" if-shell "*)
                count=0
                if [ -f \(shellQuotedCommandArgument(counter.path)) ]; then
                    count=$(cat \(shellQuotedCommandArgument(counter.path)))
                fi
                count=$((count + 1))
                printf '%s\\n' "$count" > \(shellQuotedCommandArgument(counter.path))
                if [ "$count" -eq 1 ]; then
                    printf 'same\\n'
                else
                    printf 'same\\n\\n'
                fi
                ;;
            *" display-message "*)
                printf '1\\n'
                ;;
        esac
        """.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmux.path
        )
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in .success(tmux.path) },
            runner: { _, command in
                AccountCommandRunner.runLoginShell(
                    shell: "/bin/sh",
                    command: command,
                    timeout: 10
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )

        let first = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )
        let second = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )

        #expect(first != second)
    }

    @Test("repeated output advances the activity fingerprint")
    func tracksRepeatedOutputProgress() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let tmux = directory.appendingPathComponent("tmux")
        let counter = directory.appendingPathComponent("history-count")
        try """
        #!/bin/sh
        case " $* " in
            *" display-message "*"GHOSTHUB_TMUX_ACTIVITY_IDENTITY"*)
                printf 'GHOSTHUB_TMUX_ACTIVITY_IDENTITY\\t1234\\t$7\\t1720000000\\t%%2\\t120x30\\n'
                ;;
            *" display-message "*)
                count=160
                if [ -f \(shellQuotedCommandArgument(counter.path)) ]; then
                    count=$(cat \(shellQuotedCommandArgument(counter.path)))
                fi
                count=$((count + 1))
                printf '%s\\n' "$count" > \(shellQuotedCommandArgument(counter.path))
                printf '%s\\n' "$count"
                ;;
            *" if-shell "*)
                printf 'repeat\\nrepeat\\n'
                ;;
        esac
        """.write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmux.path
        )
        let probe = TmuxSessionActivityProbe(
            pathResolver: { _ in .success(tmux.path) },
            runner: { _, command in
                AccountCommandRunner.runLoginShell(
                    shell: "/bin/sh",
                    command: command,
                    timeout: 10
                )
            }
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )

        let first = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )
        let second = await probe.sample(
            selection,
            expectedIdentity: activityIdentity,
            on: .local
        )

        #expect(first != second)
    }
}

/// A fake tmux that tracks the current session identity in a state file,
/// answers identity reads from it, and evaluates the probe's embedded
/// identity predicates against it, so replacement races exercise the same
/// compare-and-act contract as a real server. A bare capture-pane call,
/// which bypasses that predicate, records a leak file.
private func statefulFakeTmux(
    directory: URL,
    replacesAfterFirstIdentityRead: Bool,
    capture: String
) -> String {
    let state = shellQuotedCommandArgument(
        directory.appendingPathComponent("identity-state").path
    )
    let flipped = shellQuotedCommandArgument(
        directory.appendingPathComponent("identity-flipped").path
    )
    let leak = shellQuotedCommandArgument(
        directory.appendingPathComponent("captured-leak").path
    )
    return """
    #!/bin/sh
    ghosthub_args=" $* "
    if [ ! -f \(state) ]; then
        printf '1234 $7 1720000000' > \(state)
    fi
    ghosthub_state=$(cat \(state))
    set -- $ghosthub_state
    ghosthub_pid=$1
    ghosthub_sid=$2
    ghosthub_created=$3
    ghosthub_match=0
    case "$ghosthub_args" in
        *"#{==:#{pid},$ghosthub_pid}"*)
            case "$ghosthub_args" in
                *"#{==:#{session_id},$ghosthub_sid}"*)
                    case "$ghosthub_args" in
                        *"#{==:#{session_created},$ghosthub_created}"*)
                            ghosthub_match=1
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac
    case "$ghosthub_args" in
        *"GHOSTHUB_TMUX_ACTIVITY_IDENTITY"*)
            printf 'GHOSTHUB_TMUX_ACTIVITY_IDENTITY\\t%s\\t%s\\t%s\\t%%2\\t120x30\\n' \\
                "$ghosthub_pid" "$ghosthub_sid" "$ghosthub_created"
            if \(replacesAfterFirstIdentityRead ? "true" : "false") \\
                && [ ! -f \(flipped) ]; then
                touch \(flipped)
                printf '9999 $8 1720000099' > \(state)
            fi
            ;;
        *" if-shell "*)
            if [ "$ghosthub_match" -eq 1 ]; then
                \(capture)
            else
                printf 'GHOSTHUB_TMUX_ACTIVITY_MISMATCH\\n'
            fi
            ;;
        *"#{?"*)
            if [ "$ghosthub_match" -eq 1 ]; then
                printf '5\\n'
            else
                printf 'GHOSTHUB_TMUX_ACTIVITY_MISMATCH\\n'
            fi
            ;;
        *" capture-pane "*)
            printf '1\\n' > \(leak)
            printf 'directly captured scrollback\\n'
            ;;
    esac
    """
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        value = true
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private actor ActivitySampleQueue {
    private var samples: [TmuxSessionActivityProbeResult]

    init(_ samples: [TmuxSessionActivityProbeResult]) {
        self.samples = samples
    }

    func next() -> TmuxSessionActivityProbeResult {
        samples.removeFirst()
    }
}

@Suite("Warm tmux session activity")
@MainActor
struct TmuxSessionActivityControllerTests {
    @Test("quiet sessions refresh their window count within twenty seconds")
    func windowCountCadence() async {
        let queue = ActivitySampleQueue([
            .sample(
                paneID: "%2",
                dimensions: "120x30",
                fingerprint: "baseline",
                windowCount: 1
            ),
            .sample(
                paneID: "%2",
                dimensions: "120x30",
                fingerprint: "changed",
                windowCount: 2
            ),
        ])
        let controller = TmuxSessionActivityController(
            sampler: { _, _, _ in await queue.next() },
            workingSampleInterval: 5,
            quietSampleInterval: 20,
            automaticallyPolls: false
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)

        controller.warm(
            selection,
            identity: activityIdentity,
            on: .local,
            at: start
        )
        await controller.sampleWarmSessions(at: start)
        #expect(controller.windowCountsBySessionID[selection.id] == 1)

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(19)
        )
        #expect(controller.windowCountsBySessionID[selection.id] == 1)

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(controller.windowCountsBySessionID[selection.id] == 2)
    }

    @Test("a baseline is quiet and later output becomes temporarily active")
    func outputTransitionLifecycle() async {
        let queue = ActivitySampleQueue([
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "baseline"),
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "changed"),
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "changed"),
        ])
        let controller = TmuxSessionActivityController(
            sampler: { _, _, _ in await queue.next() },
            activityDuration: 30,
            workingSampleInterval: 5,
            quietSampleInterval: 20,
            automaticallyPolls: false
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)

        controller.warm(
            selection,
            identity: activityIdentity,
            on: .local,
            at: start
        )
        await controller.sampleWarmSessions(at: start)
        #expect(controller.workingSessionIDs.isEmpty)

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(controller.workingSessionIDs == [selection.id])

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(50)
        )
        #expect(controller.workingSessionIDs.isEmpty)
    }

    @Test("switching active panes establishes a quiet baseline")
    func paneSwitchIsQuiet() async {
        let queue = ActivitySampleQueue([
            .sample(paneID: "%1", dimensions: "120x30", fingerprint: "baseline:100"),
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "baseline:200"),
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "changed:220"),
        ])
        let controller = TmuxSessionActivityController(
            sampler: { _, _, _ in await queue.next() },
            activityDuration: 30,
            workingSampleInterval: 5,
            quietSampleInterval: 20,
            automaticallyPolls: false
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        controller.warm(
            selection,
            identity: activityIdentity,
            on: .local,
            at: start
        )

        await controller.sampleWarmSessions(at: start)
        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(controller.workingSessionIDs.isEmpty)

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(40)
        )
        #expect(controller.workingSessionIDs == [selection.id])
    }

    @Test("a pane resize establishes a quiet baseline")
    func paneResizeIsQuiet() async {
        let queue = ActivitySampleQueue([
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "wide"),
            .sample(paneID: "%2", dimensions: "80x30", fingerprint: "narrow"),
            .sample(paneID: "%2", dimensions: "80x30", fingerprint: "output"),
        ])
        let controller = TmuxSessionActivityController(
            sampler: { _, _, _ in await queue.next() },
            activityDuration: 30,
            workingSampleInterval: 5,
            quietSampleInterval: 20,
            automaticallyPolls: false
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        controller.warm(
            selection,
            identity: activityIdentity,
            on: .local,
            at: start
        )

        await controller.sampleWarmSessions(at: start)
        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(controller.workingSessionIDs.isEmpty)

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(40)
        )
        #expect(controller.workingSessionIDs == [selection.id])
    }

    @Test("recovery after a sampling outage establishes a quiet baseline")
    func outageRecoveryIsQuiet() async {
        let queue = ActivitySampleQueue([
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "baseline"),
            .unavailable,
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "outage"),
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "fresh"),
        ])
        let controller = TmuxSessionActivityController(
            sampler: { _, _, _ in await queue.next() },
            activityDuration: 30,
            workingSampleInterval: 5,
            quietSampleInterval: 20,
            failureSampleInterval: 30,
            automaticallyPolls: false
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        controller.warm(
            selection,
            identity: activityIdentity,
            on: .local,
            at: start
        )

        await controller.sampleWarmSessions(at: start)
        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(50)
        )
        #expect(controller.workingSessionIDs.isEmpty)

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(70)
        )
        #expect(controller.workingSessionIDs == [selection.id])
    }

    @Test("reconciling endpoints retires changed and removed hosts only")
    func reconcileRetiresStaleEndpoints() async {
        let sampled = LockedValue<[String]>([])
        let fingerprints = LockedValue(0)
        let controller = TmuxSessionActivityController(
            sampler: { selection, _, _ in
                sampled.withLock { $0.append(selection.name) }
                var fingerprint = 0
                fingerprints.withLock { count in
                    count += 1
                    fingerprint = count
                }
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: "output-\(fingerprint)"
                )
            },
            automaticallyPolls: false
        )
        let keptHostID = UUID()
        let movedHostID = UUID()
        let removedHostID = UUID()
        let oldEndpoint = CommandHost.ssh(SSHHostInfo(
            user: "wes",
            hostname: "old-box",
            port: nil,
            platform: .posix
        ))
        let newEndpoint = CommandHost.ssh(SSHHostInfo(
            user: "wes",
            hostname: "new-box",
            port: nil,
            platform: .posix
        ))
        let kept = WorkspaceTmuxSessionSelection(
            hostID: keptHostID,
            name: "kept"
        )
        let moved = WorkspaceTmuxSessionSelection(
            hostID: movedHostID,
            name: "moved"
        )
        let removed = WorkspaceTmuxSessionSelection(
            hostID: removedHostID,
            name: "removed"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        controller.warm(kept, identity: activityIdentity, on: .local, at: start)
        controller.warm(
            moved,
            identity: activityIdentity,
            on: oldEndpoint,
            at: start
        )
        controller.warm(
            removed,
            identity: activityIdentity,
            on: oldEndpoint,
            at: start
        )
        await controller.sampleWarmSessions(at: start)
        #expect(controller.workingSessionIDs.isEmpty)

        controller.reconcile(endpointsByHostID: [
            keptHostID: .local,
            movedHostID: newEndpoint,
        ])
        sampled.withLock { $0.removeAll() }
        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )

        #expect(sampled.load() == ["kept"])
        #expect(controller.workingSessionIDs == [kept.id])
    }

    @Test("polling publishes only changed working membership")
    func pollingPublishesOnlyChangedMembership() async {
        let queue = ActivitySampleQueue([
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "baseline"),
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "changed"),
            .sample(paneID: "%2", dimensions: "120x30", fingerprint: "changed"),
        ])
        let controller = TmuxSessionActivityController(
            sampler: { _, _, _ in await queue.next() },
            workingSampleInterval: 5,
            quietSampleInterval: 20,
            automaticallyPolls: false
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "quiet"
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        controller.warm(
            selection,
            identity: activityIdentity,
            on: .local,
            at: start
        )
        await controller.sampleWarmSessions(at: start)
        var updateCount = 0
        let updates = controller.objectWillChange.sink {
            updateCount += 1
        }

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(1)
        )
        #expect(updateCount == 0)

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(20)
        )
        #expect(controller.workingSessionIDs == [selection.id])
        updateCount = 0

        await controller.sampleWarmSessions(
            at: start.addingTimeInterval(25)
        )
        #expect(updateCount == 0)
        withExtendedLifetime(updates) {}
    }

    @Test("a blocked probe does not delay another session result")
    func probesDueSessionsConcurrently() async {
        let hostID = UUID()
        let slow = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "slow"
        )
        let fast = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "fast"
        )
        let sampleCounts = LockedValue<[String: Int]>([:])
        let secondStarts = LockedValue<Set<String>>([])
        let bothStarted = AsyncStream<Void>.makeStream()
        let releaseSlow = AsyncStream<Void>.makeStream()
        let controller = TmuxSessionActivityController(
            sampler: { selection, _, _ in
                var sampleCount = 0
                sampleCounts.withLock { counts in
                    counts[selection.id, default: 0] += 1
                    sampleCount = counts[selection.id] ?? 0
                }
                guard sampleCount > 1 else {
                    return .sample(
                        paneID: "%2",
                        dimensions: "120x30",
                        fingerprint: "baseline"
                    )
                }
                secondStarts.withLock { starts in
                    _ = starts.insert(selection.id)
                }
                if secondStarts.load().count == 2 {
                    bothStarted.continuation.yield()
                }
                if selection.id == slow.id {
                    for await _ in releaseSlow.stream {
                        break
                    }
                    return .unavailable
                }
                for await _ in bothStarted.stream {
                    break
                }
                return .sample(paneID: "%2", dimensions: "120x30", fingerprint: "changed")
            },
            automaticallyPolls: false
        )
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        controller.warm(
            slow,
            identity: activityIdentity,
            on: .local,
            at: start
        )
        controller.warm(
            fast,
            identity: activityIdentity,
            on: .local,
            at: start
        )
        await controller.sampleWarmSessions(at: start)

        let secondRound = Task { @MainActor in
            await controller.sampleWarmSessions(
                at: start.addingTimeInterval(20)
            )
        }
        await waitUntilMainActor {
            controller.workingSessionIDs.contains(fast.id)
        }
        #expect(controller.workingSessionIDs.contains(fast.id))

        let thirdTickFinished = LockedValue(false)
        let thirdTick = Task { @MainActor in
            await controller.sampleWarmSessions(
                at: start.addingTimeInterval(25)
            )
            thirdTickFinished.store(true)
        }
        await waitUntilMainActor {
            thirdTickFinished.load()
        }
        #expect(thirdTickFinished.load())
        #expect(sampleCounts.load()[fast.id] == 3)

        bothStarted.continuation.yield()
        releaseSlow.continuation.yield()
        releaseSlow.continuation.yield()
        await thirdTick.value
        await secondRound.value
    }

    @Test("a slow quiet probe still reports fresh activity")
    func slowProbeCountsChangesFromItsStart() async {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let clock = LockedValue(start)
        let sampleCount = LockedValue(0)
        let controller = TmuxSessionActivityController(
            sampler: { _, _, _ in
                var current = 0
                sampleCount.withLock { count in
                    count += 1
                    current = count
                }
                if current == 1 {
                    return .sample(
                        paneID: "%2",
                        dimensions: "120x30",
                        fingerprint: "baseline"
                    )
                }
                clock.withLock { $0 = $0.addingTimeInterval(40) }
                return .sample(
                    paneID: "%2",
                    dimensions: "120x30",
                    fingerprint: "changed"
                )
            },
            activityDuration: 30,
            workingSampleInterval: 5,
            quietSampleInterval: 20,
            now: { clock.load() },
            automaticallyPolls: false
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )
        controller.warm(
            selection,
            identity: activityIdentity,
            on: .local,
            at: start
        )
        await controller.sampleWarmSessions()
        #expect(controller.workingSessionIDs.isEmpty)

        clock.store(start.addingTimeInterval(25))
        await controller.sampleWarmSessions()

        #expect(controller.workingSessionIDs == [selection.id])
    }

    @Test("a blocked probe expires activity at completion")
    func blockedProbeUsesCompletionTime() async {
        let sampleCount = LockedValue(0)
        let controller = TmuxSessionActivityController(
            sampler: { _, _, _ in
                var current = 0
                sampleCount.withLock { count in
                    count += 1
                    current = count
                }
                switch current {
                case 1:
                    return .sample(
                        paneID: "%2",
                        dimensions: "120x30",
                        fingerprint: "baseline"
                    )
                case 2:
                    return .sample(
                        paneID: "%2",
                        dimensions: "120x30",
                        fingerprint: "changed"
                    )
                default:
                    try? await Task.sleep(for: .milliseconds(300))
                    return .unavailable
                }
            },
            activityDuration: 0.15,
            workingSampleInterval: 0,
            quietSampleInterval: 0,
            automaticallyPolls: false
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: UUID(),
            name: "build"
        )
        let start = Date.now
        controller.warm(
            selection,
            identity: activityIdentity,
            on: .local,
            at: start
        )
        await controller.sampleWarmSessions(at: start)
        await controller.sampleWarmSessions(at: start)
        #expect(controller.workingSessionIDs == [selection.id])

        await controller.sampleWarmSessions()

        #expect(controller.workingSessionIDs.isEmpty)
    }
}
