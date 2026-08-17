import Foundation
import GhosthubTerminalSupport
import GhosthubTestSupport
import GhosthubTmux
import GhosthubTransport
import Testing
@testable import GhosthubApp

private let testSplitClient = TmuxPaneSplitClientIdentity(
    serverPID: "123",
    clientPID: "789",
    clientCreatedAt: "321",
    clientTTY: "/dev/ttys001",
    sessionID: "$7",
    sessionCreatedAt: "456",
    paneID: "%9"
)

private func testClientTokenPath(
    _ token: String,
    directory: URL? = nil
) throws -> URL {
    if let directory {
        return directory.appendingPathComponent(token)
    }
    let shellHome = try #require(
        ProcessInfo.processInfo.environment["HOME"]
    )
    return URL(fileURLWithPath: shellHome, isDirectory: true)
        .appendingPathComponent(
            ".ghosthub/tmux-clients/\(token)"
        )
}

private enum PublishedClientTTYError: LocalizedError {
    case processExited(Int32)
    case timedOut

    var errorDescription: String? {
        switch self {
        case let .processExited(status):
            "tmux client exited before publishing its TTY (status \(status))"
        case .timedOut:
            "tmux client did not publish its TTY within 30 seconds"
        }
    }
}

private func publishedClientTTY(
    at tokenPath: URL,
    whileRunning process: Process
) async throws -> String {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while clock.now < deadline {
        let published = ((try? String(
            contentsOf: tokenPath,
            encoding: .utf8
        )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !published.isEmpty {
            return published
        }
        guard process.isRunning else {
            throw PublishedClientTTYError.processExited(
                process.terminationStatus
            )
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw PublishedClientTTYError.timedOut
}

private final class TestTmuxClient {
    let process = Process()
    private let input = Pipe()
    private let tokenPath: URL

    init(
        tmuxPath: String,
        socketName: String,
        sessionName: String,
        clientToken: String,
        clientTTYDirectory: URL? = nil
    ) throws {
        tokenPath = try testClientTokenPath(
            clientToken,
            directory: clientTTYDirectory
        )
        let command = TmuxAttachmentInfo(
            sessionName: sessionName,
            host: .local,
            socketName: socketName,
            launchMode: .attachOnly
        ).attachCommand(
            tmuxPath: tmuxPath,
            clientTTYToken: clientToken,
            localClientTTYDirectory: clientTTYDirectory?.path
        )
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null", "/bin/sh", "-c", command,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TERM": "xterm-256color",
        ]) { _, new in new }
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func stop() {
        if process.isRunning {
            process.terminate()
        }
        try? FileManager.default.removeItem(at: tokenPath)
    }

    func publishedTTY() async throws -> String {
        try await publishedClientTTY(at: tokenPath, whileRunning: process)
    }
}

private func makeTestTmuxServer(
    tmuxPath: String,
    purpose: String,
    sessions: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    commandRunner: TestTmuxServer.CommandRunner? = nil
) throws -> TestTmuxServer {
    let server = try TestTmuxServer(
        tmuxPath: tmuxPath,
        socket: .runOwned(purpose: purpose),
        environment: environment,
        commandRunner: commandRunner
    )
    for session in sessions {
        try server.createSession(session)
    }
    return server
}

private struct TestTmuxLoginShell: Sendable {
    let shell: String
    let environment: [String: String]

    init(shell: String, environment: [String: String]) throws {
        self.shell = shell
        self.environment = environment
        _ = try #require(environment["TMUX_TMPDIR"])
    }

    func run(
        command: String,
        timeout: TimeInterval,
        captureStandardError: Bool = false,
        environment: [String: String]? = nil
    ) -> (status: Int32, stdout: String) {
        let environment = environment ?? self.environment
        let tmuxDirectory = environment["TMUX_TMPDIR"] ?? ""
        return AccountCommandRunner.runLoginShell(
            shell: shell,
            command: "export TMUX_TMPDIR="
                + shellQuotedCommandArgument(tmuxDirectory)
                + "; " + command,
            timeout: timeout,
            captureStandardError: captureStandardError,
            environmentOverrides: ["TMUX_TMPDIR": tmuxDirectory]
        )
    }

    func commandRunner() -> TestTmuxServer.CommandRunner {
        { executable, arguments, timeout, environment in
            let command = ([executable] + arguments)
                .map(shellQuotedCommandArgument)
                .joined(separator: " ")
            let result = run(
                command: command,
                timeout: timeout,
                captureStandardError: true,
                environment: environment
            )
            return TestTmuxCommandOutput(
                status: result.status,
                stderr: result.stdout
            )
        }
    }

    func paneRunner() -> TmuxPaneSplitter.Runner {
        { host, _, command in
            guard host == .local else {
                return (127, "test login-shell runner only supports localhost")
            }
            let result = run(
                command: command,
                timeout: 15,
                captureStandardError: true
            )
            return (result.status, result.stdout)
        }
    }
}

private func nativePaneSplitsAreAvailable(_ tmuxPath: String) -> Bool {
    guard case let .success(binary) =
        TmuxBinaryResolver().resolveTmuxBinary()
    else { return false }
    return TmuxPaneSplitter.supportsPaneSplitting(
        version: binary.version,
        host: .local
    )
}

@Suite("tmux pane splitting", .serialized)
struct TmuxPaneSplitterTests {
    @Test("version capability requires tmux 3.4")
    func versionCapabilityRequiresTmux34() {
        #expect(TmuxPaneSplitter.supportsPaneSplitting(
            version: "tmux 3.4a",
            host: .local
        ))
        #expect(!TmuxPaneSplitter.supportsPaneSplitting(
            version: "tmux 3.3a",
            host: .local
        ))
        #expect(!TmuxPaneSplitter.supportsPaneSplitting(
            version: "tmux 3.6",
            host: .ssh(SSHHostInfo(
                user: nil,
                hostname: "windows.example.test",
                port: nil,
                platform: .windows
            ))
        ))
    }

    @Test("custom prefix and key bindings do not affect semantic splits")
    func customizedBindings() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else {
            return
        }
        guard nativePaneSplitsAreAvailable(tmuxPath) else { return }
        let server = try makeTestTmuxServer(
            tmuxPath: tmuxPath,
            purpose: "split",
            sessions: ["customized"]
        )
        defer { server.stop() }
        let socketName = server.socketName
        let customized = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName,
                "set-option", "-g", "prefix", "C-a", ";",
                "unbind-key", "%", ";",
                "unbind-key", #"""#,
            ],
            timeout: 5
        )
        #expect(customized.status == 0)

        let unresolvedTarget = TmuxPaneSplitTarget(
            host: .local,
            tmuxPath: tmuxPath,
            sessionName: "customized",
            socketName: socketName,
            sshConnectionArguments: [],
            clientToken: UUID().uuidString.lowercased()
        )
        let unrelatedClient = try TestTmuxClient(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: "customized",
            clientToken: UUID().uuidString.lowercased()
        )
        defer { unrelatedClient.stop() }
        let clientProcess = try TestTmuxClient(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: "customized",
            clientToken: unresolvedTarget.clientToken ?? ""
        )
        defer { clientProcess.stop() }
        var attachedClientCount = 0
        for _ in 0 ..< 100 where attachedClientCount != 2 {
            let listed = AccountCommandRunner.runProcess(
                executable: tmuxPath,
                arguments: [
                    "-L", socketName, "list-clients", "-F", "#{client_tty}",
                ],
                timeout: 5
            )
            attachedClientCount = listed.stdout
                .split(whereSeparator: \.isNewline).count
            if attachedClientCount != 2 {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(attachedClientCount == 2)
        let expectedTTY = try await clientProcess.publishedTTY()
        let initialClient = try? await TmuxPaneSplitter().clientIdentity(
            target: unresolvedTarget
        ).get()
        #expect(initialClient != nil)
        let renamed = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName,
                "rename-session", "-t", "=customized:", "renamed",
            ],
            timeout: 5
        )
        #expect(renamed.status == 0)

        var renamedTarget = unresolvedTarget
        renamedTarget.expectedIdentity = initialClient?.sessionIdentity
        renamedTarget.expectedClient = initialClient
        let client = try? await TmuxPaneSplitter().clientIdentity(
            target: renamedTarget
        ).get()
        #expect(client != nil)
        #expect(client?.clientTTY == expectedTTY)

        let failure = await TmuxPaneSplitter().split(
            .right,
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: tmuxPath,
                sessionName: "customized",
                socketName: socketName,
                sshConnectionArguments: [],
                expectedIdentity: client?.sessionIdentity,
                expectedClient: client
            )
        )
        #expect(failure == nil)
        let hooks = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: ["-L", socketName, "show-hooks", "-g"],
            timeout: 5
        )
        #expect(!hooks.stdout.split(whereSeparator: \.isNewline)
            .contains(where: { $0.hasPrefix("after-refresh-client[") }))

        let panes = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "list-panes", "-t", "=renamed:",
                "-F", "#{pane_id}",
            ],
            timeout: 5
        )
        #expect(panes.status == 0)
        #expect(panes.stdout.split(whereSeparator: \.isNewline).count == 2)
    }

    @Test("concurrent split hooks remain isolated by request marker")
    func concurrentHooksRemainIsolated() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else { return }
        guard nativePaneSplitsAreAvailable(tmuxPath) else { return }
        let server = try makeTestTmuxServer(
            tmuxPath: tmuxPath,
            purpose: "concurrent-hooks",
            sessions: ["concurrent-a", "concurrent-b"]
        )
        defer { server.stop() }
        let socketName = server.socketName

        let firstToken = UUID().uuidString.lowercased()
        let secondToken = UUID().uuidString.lowercased()
        let firstClientTarget = TmuxPaneSplitTarget(
            host: .local,
            tmuxPath: tmuxPath,
            sessionName: "concurrent-a",
            socketName: socketName,
            sshConnectionArguments: [],
            clientToken: firstToken
        )
        let secondClientTarget = TmuxPaneSplitTarget(
            host: .local,
            tmuxPath: tmuxPath,
            sessionName: "concurrent-b",
            socketName: socketName,
            sshConnectionArguments: [],
            clientToken: secondToken
        )
        let firstClientProcess = try TestTmuxClient(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: "concurrent-a",
            clientToken: firstToken
        )
        defer { firstClientProcess.stop() }
        let secondClientProcess = try TestTmuxClient(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: "concurrent-b",
            clientToken: secondToken
        )
        defer { secondClientProcess.stop() }
        _ = try await firstClientProcess.publishedTTY()
        _ = try await secondClientProcess.publishedTTY()
        let splitter = TmuxPaneSplitter()
        let firstClient = try await splitter.clientIdentity(
            target: firstClientTarget
        ).get()
        let secondClient = try await splitter.clientIdentity(
            target: secondClientTarget
        ).get()

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let barrierDirectory = temporaryDirectory.appendingPathComponent(
            "barrier",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: barrierDirectory,
            withIntermediateDirectories: false
        )
        let shimURL = temporaryDirectory.appendingPathComponent("tmux")
        let shim = """
        #!/bin/sh
        set -eu
        if [ "${3-}" = set-hook ] && [ "${4-}" = -g ] \
            && [ "${8-}" = refresh-client ]; then
          ghosthub_socket=$2
          ghosthub_hook=$5
          ghosthub_body=$6
          ghosthub_tty=${10}
          ghosthub_marker=${11}
          ghosthub_cleanup_hook=${15}
          \(shellQuotedCommandArgument(tmuxPath)) -L "$ghosthub_socket" \
            set-hook -g "$ghosthub_hook" "$ghosthub_body"
          : > \(shellQuotedCommandArgument(barrierDirectory.path))/"$ghosthub_hook"
          ghosthub_attempt=0
          while [ "$ghosthub_attempt" -lt 500 ]; do
            set -- \(shellQuotedCommandArgument(barrierDirectory.path))/*
            [ "$#" -ge 2 ] && break
            ghosthub_attempt=$((ghosthub_attempt + 1))
            sleep 0.01
          done
          [ "$#" -ge 2 ] || exit 99
          \(shellQuotedCommandArgument(tmuxPath)) -L "$ghosthub_socket" \
            refresh-client -t "$ghosthub_tty" "$ghosthub_marker" ';' \
            set-hook -gu "$ghosthub_cleanup_hook"
          exit $?
        fi
        exec \(shellQuotedCommandArgument(tmuxPath)) "$@"
        """
        try Data(shim.utf8).write(to: shimURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: shimURL.path
        )

        let firstSplitTarget = TmuxPaneSplitTarget(
            host: .local,
            tmuxPath: shimURL.path,
            sessionName: "concurrent-a",
            socketName: socketName,
            sshConnectionArguments: [],
            expectedIdentity: firstClient.sessionIdentity,
            expectedClient: firstClient
        )
        let secondSplitTarget = TmuxPaneSplitTarget(
            host: .local,
            tmuxPath: shimURL.path,
            sessionName: "concurrent-b",
            socketName: socketName,
            sshConnectionArguments: [],
            expectedIdentity: secondClient.sessionIdentity,
            expectedClient: secondClient
        )
        async let first = splitter.split(.right, target: firstSplitTarget)
        async let second = splitter.split(.down, target: secondSplitTarget)
        let failures = await (first, second)

        #expect(failures.0 == nil)
        #expect(failures.1 == nil)
        for sessionName in ["concurrent-a", "concurrent-b"] {
            let panes = AccountCommandRunner.runProcess(
                executable: tmuxPath,
                arguments: [
                    "-L", socketName, "list-panes", "-t", "=\(sessionName):",
                    "-F", "#{pane_id}",
                ],
                timeout: 5
            )
            #expect(panes.stdout.split(whereSeparator: \.isNewline).count == 2)
        }
    }

    @Test("client identity waits for attachment TTY publication")
    func clientIdentityWaitsForTTYPublication() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else { return }
        let server = try makeTestTmuxServer(
            tmuxPath: tmuxPath,
            purpose: "token-race",
            sessions: ["token-race"]
        )
        defer { server.stop() }
        let socketName = server.socketName

        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }
        let token = UUID().uuidString.lowercased()
        let clientTTYDirectory = stateDirectory.appendingPathComponent(
            "isolated-state/tmux-clients", isDirectory: true
        )
        let target = TmuxPaneSplitTarget(
            host: .local,
            tmuxPath: tmuxPath,
            sessionName: "token-race",
            socketName: socketName,
            sshConnectionArguments: [],
            clientToken: token,
            clientTTYDirectory: clientTTYDirectory.path
        )
        let runnerStarted = LockedValue(false)
        let releaseRunner = DispatchSemaphore(value: 0)
        let splitter = TmuxPaneSplitter { _, _, command in
            runnerStarted.store(true)
            releaseRunner.wait()
            let result = AccountCommandRunner.runLoginShell(
                shell: AccountCommandRunner.loginShell(),
                command: command,
                timeout: 15,
                captureStandardError: true
            )
            return (result.status, result.stdout)
        }
        async let pendingIdentity = splitter.clientIdentity(target: target)
        for _ in 0 ..< 100 where !runnerStarted.load() {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(runnerStarted.load())
        releaseRunner.signal()
        try await Task.sleep(for: .milliseconds(50))

        let clientProcess = try TestTmuxClient(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: "token-race",
            clientToken: token,
            clientTTYDirectory: clientTTYDirectory
        )
        defer { clientProcess.stop() }
        let client = try await pendingIdentity.get()

        #expect(client.clientTTY.hasPrefix("/dev/"))
        #expect(client.sessionIdentity.sessionID.hasPrefix("$"))
    }

    @Test("client identity resolves after slow attachment startup")
    func slowAttachmentIdentityResolvesOnDemand() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else { return }
        guard nativePaneSplitsAreAvailable(tmuxPath) else { return }
        let server = try makeTestTmuxServer(
            tmuxPath: tmuxPath,
            purpose: "slow-split",
            sessions: ["slow"]
        )
        defer { server.stop() }
        let socketName = server.socketName

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let kwt = directory.appendingPathComponent("kwt")
        try """
        #!/bin/sh
        sleep 6.5
        exec "$GHOSTHUB_TEST_TMUX" -L "$GHOSTHUB_TEST_TMUX_SOCKET" \
          attach-session -E -t '=slow'
        """.write(to: kwt, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: kwt.path
        )

        let token = UUID().uuidString.lowercased()
        let tokenPath = try testClientTokenPath(token)
        defer { try? FileManager.default.removeItem(at: tokenPath) }
        let command = TmuxAttachmentInfo(
            sessionName: "slow",
            host: .local,
            socketName: socketName,
            workspacePath: "/tmp/slow"
        ).attachCommand(
            tmuxPath: tmuxPath,
            kwtPath: kwt.path,
            clientTTYToken: token
        )
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TERM": "xterm-256color",
            "GHOSTHUB_TEST_TMUX": tmuxPath,
            "GHOSTHUB_TEST_TMUX_SOCKET": socketName,
        ]) { _, new in new }
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let publishedTTY = try await publishedClientTTY(
            at: tokenPath,
            whileRunning: process
        )
        #expect(publishedTTY.hasPrefix("/dev/"))

        let target = TmuxPaneSplitTarget(
            host: .local,
            tmuxPath: tmuxPath,
            sessionName: "slow",
            socketName: socketName,
            sshConnectionArguments: [],
            clientToken: token
        )
        let earlyClient = try? await TmuxPaneSplitter().clientIdentity(
            target: target
        ).get()
        #expect(earlyClient == nil)
        let client = try await TmuxPaneSplitter().clientIdentity(
            target: target
        ).get()
        var resolvedTarget = target
        resolvedTarget.expectedIdentity = client.sessionIdentity
        resolvedTarget.expectedClient = client
        #expect(await TmuxPaneSplitter().split(
            .right,
            target: resolvedTarget
        ) == nil)
    }

    @Test("identity publication ignores launcher tmux and session renames")
    func identityPublicationUsesAttachedClient() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-login-tmux-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let profileTmuxDirectory = directory
            .appendingPathComponent("profile-tmux", isDirectory: true).path
        let shell = directory.appendingPathComponent("login-shell")
        try """
        #!/bin/sh
        export TMUX_TMPDIR=\(shellQuotedCommandArgument(profileTmuxDirectory))
        exec /bin/sh "$@"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: shell.path
        )
        let rawLoginEnvironment = AccountCommandRunner.runLoginShell(
            shell: shell.path,
            command: "/usr/bin/printenv TMUX_TMPDIR",
            timeout: 5
        )
        #expect(
            rawLoginEnvironment.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == profileTmuxDirectory
        )
        let fixtureEnvironment = ProcessInfo.processInfo.environment
        let tmuxLoginShell = try TestTmuxLoginShell(
            shell: shell.path,
            environment: fixtureEnvironment
        )
        let commandRunner = tmuxLoginShell.commandRunner()
        let targetServer = try makeTestTmuxServer(
            tmuxPath: tmuxPath,
            purpose: "target",
            sessions: ["inherited-target"],
            environment: fixtureEnvironment,
            commandRunner: commandRunner
        )
        let launcherServer = try makeTestTmuxServer(
            tmuxPath: tmuxPath,
            purpose: "launcher",
            sessions: ["launcher"],
            environment: fixtureEnvironment,
            commandRunner: commandRunner
        )
        let targetSocketName = targetServer.socketName
        let launcherSocketName = launcherServer.socketName
        let token = UUID().uuidString.lowercased()
        let tokenPath = try testClientTokenPath(token)
        defer {
            targetServer.stop()
            launcherServer.stop()
            try? FileManager.default.removeItem(at: tokenPath)
        }
        let renameHook = [
            tmuxPath, "-L", targetSocketName, "set-hook", "-g",
            "client-attached",
            "rename-session -t =inherited-target: inherited-renamed",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        #expect(tmuxLoginShell.run(
            command: renameHook,
            timeout: 5
        ).status == 0)
        let launcherIdentity = [
            tmuxPath, "-L", launcherSocketName, "display-message", "-p",
            "#{socket_path}\t#{pid}",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        let launcherFields = tmuxLoginShell.run(
            command: launcherIdentity,
            timeout: 5
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
        let launcherSocketPath = try #require(launcherFields.first)
        let launcherPID = try #require(launcherFields.dropFirst().first)

        let attach = TmuxAttachmentInfo(
            sessionName: "inherited-target",
            host: .local,
            socketName: targetSocketName,
            launchMode: .attachOnly
        ).attachCommand(tmuxPath: tmuxPath, clientTTYToken: token)
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", attach]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "TERM": "xterm-256color",
            "TMUX": "\(launcherSocketPath),\(launcherPID),0",
            "TMUX_PANE": "%0",
        ]) { _, new in new }
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let published = try await publishedClientTTY(
            at: tokenPath,
            whileRunning: process
        )
        let targetIdentity = [
            tmuxPath, "-L", targetSocketName, "display-message", "-p", "-t",
            "=inherited-renamed:",
            "#{pid}\t#{session_id}\t#{session_created}",
        ].map(shellQuotedCommandArgument).joined(separator: " ")
        let targetIdentityResult = tmuxLoginShell.run(
            command: targetIdentity,
            timeout: 5
        )
        let targetFields = targetIdentityResult.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")

        let client = try await TmuxPaneSplitter(
            runner: tmuxLoginShell.paneRunner()
        ).clientIdentity(
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: tmuxPath,
                sessionName: "inherited-target",
                socketName: targetSocketName,
                sshConnectionArguments: [],
                clientToken: token
            )
        ).get()
        #expect(published.split(whereSeparator: \.isNewline).count == 1)
        #expect(targetIdentityResult.status == 0)
        #expect(targetFields.count == 3)
        #expect(client.serverPID == targetFields.first.map(String.init))
        #expect(
            client.sessionID == targetFields.dropFirst().first.map(String.init)
        )
        #expect(client.sessionCreatedAt == targetFields.last.map(String.init))
        #expect(client.serverPID != String(launcherPID))
    }

    @Test("failed splits return a concise tmux diagnostic")
    func failedSplit() async {
        let failure = await TmuxPaneSplitter { _, _, _ in
            (7, "  no space\nfor new pane  ")
        }.split(
            .right,
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: "/usr/bin/tmux",
                sessionName: "limited",
                socketName: nil,
                sshConnectionArguments: [],
                expectedIdentity: testSplitClient.sessionIdentity,
                expectedClient: testSplitClient
            )
        )

        #expect(failure == TmuxPaneSplitFailure(
            host: "localhost",
            sessionName: "limited",
            status: 7,
            diagnostic: "no space for new pane"
        ))
    }

    @Test("client identity discovery lists clients by published TTY")
    func clientIdentityUsesListClients() async throws {
        let command = LockedValue("")
        let client = try await TmuxPaneSplitter { _, _, received in
            command.store(received)
            return (
                0,
                "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY\t"
                    + "123\t789\t321\t/dev/ttys001\t$7\t456\t%9\n"
            )
        }.clientIdentity(
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: "/usr/bin/tmux",
                sessionName: "review",
                socketName: nil,
                sshConnectionArguments: [],
                clientToken: "attachment-token"
            )
        ).get()

        #expect(client == testSplitClient)
        #expect(command.load().contains("'list-clients' '-F'"))
    }

    @Test("noisy command echoes do not report an identity mismatch")
    func noisyCommandEchoIsIgnored() async {
        let failure = await TmuxPaneSplitter { _, _, command in
            (0, "+ \(command)\n")
        }.split(
            .right,
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: "/usr/bin/tmux",
                sessionName: "noisy",
                socketName: nil,
                sshConnectionArguments: [],
                expectedIdentity: testSplitClient.sessionIdentity,
                expectedClient: testSplitClient
            )
        )

        #expect(failure == nil)
    }

    @Test("only the atomic guard mismatch is retryable")
    func atomicGuardMismatchIsRetryable() async {
        let mismatch = await TmuxPaneSplitter { _, _, command in
            let prefix = "GHOSTHUB_TMUX_SPLIT_IDENTITY_MISMATCH_"
            guard let start = command.range(of: prefix)?.lowerBound else {
                return (1, "missing mismatch marker")
            }
            let marker = command[start...].prefix { character in
                character.isLetter || character.isNumber
                    || character == "_" || character == "-"
            }
            return (0, String(marker) + "\n")
        }.split(
            .right,
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: "/usr/bin/tmux",
                sessionName: "moving",
                socketName: nil,
                sshConnectionArguments: [],
                expectedIdentity: testSplitClient.sessionIdentity,
                expectedClient: testSplitClient
            )
        )
        let missingClient = await TmuxPaneSplitter { _, _, _ in
            (1, "can't find client: /dev/ttys001\n")
        }.split(
            .right,
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: "/usr/bin/tmux",
                sessionName: "missing",
                socketName: nil,
                sshConnectionArguments: [],
                expectedIdentity: testSplitClient.sessionIdentity,
                expectedClient: testSplitClient
            )
        )

        #expect(mismatch?.kind == .atomicGuardChanged)
        #expect(missingClient?.kind == .terminal)
    }

    @Test("cancellation removes an installed split hook")
    func cancellationRemovesInstalledHook() async {
        let hookInstalled = LockedValue(false)
        let splitStarted = LockedValue(false)
        let commands = LockedValue<[String]>([])
        let splitter = TmuxPaneSplitter { _, _, command in
            commands.withLock { $0.append(command) }
            if command.contains("'refresh-client'") {
                hookInstalled.store(true)
                splitStarted.store(true)
                while !withUnsafeCurrentTask(body: {
                    $0?.isCancelled == true
                }) {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            } else if command.contains("'set-hook' '-gu'") {
                hookInstalled.store(false)
            }
            return (0, "")
        }
        let task = Task {
            await splitter.split(
                .right,
                target: TmuxPaneSplitTarget(
                    host: .local,
                    tmuxPath: "/usr/bin/tmux",
                    sessionName: "cancelled",
                    socketName: nil,
                    sshConnectionArguments: [],
                    expectedIdentity: testSplitClient.sessionIdentity,
                    expectedClient: testSplitClient
                )
            )
        }

        await waitUntil { splitStarted.load() }
        task.cancel()
        _ = await task.value

        #expect(!hookInstalled.load())
        #expect(commands.load().count == 2)
    }

    @Test("validation and split share one exact-client tmux queue")
    func posixCommands() {
        let right = TmuxPaneSplitter.command(
            tmuxPath: "/opt/homebrew/bin/tmux",
            socketName: "kwt-pr-0123456789abcdef",
            shortcut: .right,
            expectedClient: testSplitClient,
            mismatchMarker: "TEST_MISMATCH",
            hookIndex: 1_500_000_001
        )
        let down = TmuxPaneSplitter.command(
            tmuxPath: "/opt/homebrew/bin/tmux",
            socketName: "kwt-pr-0123456789abcdef",
            shortcut: .down,
            expectedClient: testSplitClient,
            mismatchMarker: "TEST_MISMATCH",
            hookIndex: 1_500_000_002
        )
        let rightSyntax = AccountCommandRunner.runProcess(
            executable: "/bin/sh",
            arguments: ["-n", "-c", right],
            timeout: 5
        )
        let downSyntax = AccountCommandRunner.runProcess(
            executable: "/bin/sh",
            arguments: ["-n", "-c", down],
            timeout: 5
        )

        #expect(rightSyntax.status == 0, Comment(rawValue: rightSyntax.stderr))
        #expect(!right.contains("'list-clients' '-F'"))
        #expect(right.contains("'refresh-client' '-t' '/dev/ttys001'"))
        #expect(right.contains("'after-refresh-client["))
        #expect(right.contains("#{L:"))
        #expect(right.contains("#{==:#{client_pid},789}"))
        #expect(right.contains("#{==:#{client_created},321}"))
        #expect(right.contains("#{==:#{pane_id},%9}"))
        #expect(right.contains("split-window"))
        #expect(right.contains("-h"))
        #expect(right.contains(shellQuotedCommandArgument("TEST_MISMATCH")))
        #expect(!right.contains("=review"))
        #expect(downSyntax.status == 0, Comment(rawValue: downSyntax.stderr))
        #expect(!down.contains("'list-clients' '-F'"))
        #expect(down.contains("'refresh-client' '-t' '/dev/ttys001'"))
        #expect(down.contains("'after-refresh-client["))
        #expect(down.contains("split-window"))
        #expect(down.contains("-v"))
        #expect(!down.contains("=review"))
    }

    @Test("atomic validation rejects a replacement on the expected TTY")
    func replacementClientOnExpectedTTYIsRejected() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else { return }
        guard nativePaneSplitsAreAvailable(tmuxPath) else { return }
        let server = try makeTestTmuxServer(
            tmuxPath: tmuxPath,
            purpose: "client-identity",
            sessions: ["identity"]
        )
        defer { server.stop() }
        let socketName = server.socketName
        let originalToken = UUID().uuidString.lowercased()
        let replacementToken = UUID().uuidString.lowercased()
        let original = try TestTmuxClient(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: "identity",
            clientToken: originalToken
        )
        defer { original.stop() }
        let replacement = try TestTmuxClient(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: "identity",
            clientToken: replacementToken
        )
        defer { replacement.stop() }
        _ = try await original.publishedTTY()
        _ = try await replacement.publishedTTY()
        let splitter = TmuxPaneSplitter()
        let originalClient = try await splitter.clientIdentity(
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: tmuxPath,
                sessionName: "identity",
                socketName: socketName,
                sshConnectionArguments: [],
                clientToken: originalToken
            )
        ).get()
        let replacementClient = try await splitter.clientIdentity(
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: tmuxPath,
                sessionName: "identity",
                socketName: socketName,
                sshConnectionArguments: [],
                clientToken: replacementToken
            )
        ).get()
        var mismatchedClient = originalClient
        mismatchedClient.clientTTY = replacementClient.clientTTY
        mismatchedClient.paneID = replacementClient.paneID
        let failure = await splitter.split(
            .right,
            target: TmuxPaneSplitTarget(
                host: .local,
                tmuxPath: tmuxPath,
                sessionName: "identity",
                socketName: socketName,
                sshConnectionArguments: [],
                expectedIdentity: originalClient.sessionIdentity,
                expectedClient: mismatchedClient
            )
        )

        #expect(failure?.diagnostic == "The attached tmux session changed.")
        let panes = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "list-panes", "-t", "=identity:",
                "-F", "#{pane_id}",
            ],
            timeout: 5
        )
        #expect(panes.stdout.split(whereSeparator: \.isNewline).count == 1)
    }

    @Test("same-name replacements cannot receive a queued split")
    func replacementIsRejected() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else {
            return
        }
        guard nativePaneSplitsAreAvailable(tmuxPath) else { return }
        let server = try makeTestTmuxServer(
            tmuxPath: tmuxPath,
            purpose: "replacement",
            sessions: ["replaceable"]
        )
        defer { server.stop() }
        let socketName = server.socketName
        let target = TmuxPaneSplitTarget(
            host: .local,
            tmuxPath: tmuxPath,
            sessionName: "replaceable",
            socketName: socketName,
            sshConnectionArguments: [],
            clientToken: UUID().uuidString.lowercased()
        )
        let clientProcess = try TestTmuxClient(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: "replaceable",
            clientToken: target.clientToken ?? ""
        )
        defer { clientProcess.stop() }
        _ = try await clientProcess.publishedTTY()
        let client = try? await TmuxPaneSplitter().clientIdentity(
            target: target
        ).get()
        #expect(client != nil)
        _ = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: ["-L", socketName, "kill-session", "-t", "replaceable"],
            timeout: 5
        )
        try server.createSession("replaceable")

        var guardedTarget = target
        guardedTarget.expectedIdentity = client?.sessionIdentity
        guardedTarget.expectedClient = client
        let failure = await TmuxPaneSplitter().split(
            .right,
            target: guardedTarget
        )
        #expect(failure?.diagnostic == "The attached tmux session changed.")
        let panes = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "list-panes", "-t", "=replaceable:",
                "-F", "#{pane_id}",
            ],
            timeout: 5
        )
        #expect(panes.status == 0)
        #expect(panes.stdout.split(whereSeparator: \.isNewline).count == 1)
    }

    @Test("a client switched to another session cannot split the hidden session")
    func switchedClientIsRejected() async throws {
        guard case let .success(tmuxPath) =
            TmuxBinaryResolver().resolveTmuxPath()
        else { return }
        guard nativePaneSplitsAreAvailable(tmuxPath) else { return }
        let server = try makeTestTmuxServer(
            tmuxPath: tmuxPath,
            purpose: "client-switch",
            sessions: ["original", "visible"]
        )
        defer { server.stop() }
        let socketName = server.socketName
        let target = TmuxPaneSplitTarget(
            host: .local,
            tmuxPath: tmuxPath,
            sessionName: "original",
            socketName: socketName,
            sshConnectionArguments: [],
            clientToken: UUID().uuidString.lowercased()
        )
        let clientProcess = try TestTmuxClient(
            tmuxPath: tmuxPath,
            socketName: socketName,
            sessionName: "original",
            clientToken: target.clientToken ?? ""
        )
        defer { clientProcess.stop() }
        _ = try await clientProcess.publishedTTY()
        let tokenPath = try testClientTokenPath(target.clientToken ?? "")
        let client = try? await TmuxPaneSplitter().clientIdentity(
            target: target
        ).get()
        guard let client else {
            let listed = AccountCommandRunner.runProcess(
                executable: tmuxPath,
                arguments: [
                    "-L", socketName, "list-clients", "-F",
                    "#{client_tty}\t#{client_session}",
                ],
                timeout: 5
            )
            let tokenValue = (try? String(
                contentsOf: tokenPath,
                encoding: .utf8
            )) ?? "<missing>"
            let diagnostic = "tmux client identity was not published: "
                + "status=\(listed.status), clients=\(listed.stdout), "
                + "token=\(tokenValue)"
            Issue.record(Comment(rawValue: diagnostic))
            return
        }
        let listed = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "list-clients", "-F",
                "#{client_pid}\t#{client_name}",
            ],
            timeout: 5
        )
        let clientName = listed.stdout.split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let fields = line.split(separator: "\t", maxSplits: 1)
                guard fields.count == 2,
                      fields[0] == Substring(client.clientPID)
                else { return nil }
                return String(fields[1])
            }.first
        guard let clientName else {
            Issue.record("tmux client name was unavailable")
            return
        }
        let switched = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", socketName, "switch-client", "-c", clientName,
                "-t", "=visible:",
            ],
            timeout: 5
        )
        #expect(switched.status == 0)

        var guardedTarget = target
        guardedTarget.expectedIdentity = client.sessionIdentity
        guardedTarget.expectedClient = client
        let failure = await TmuxPaneSplitter().split(
            .right,
            target: guardedTarget
        )
        #expect(failure?.diagnostic == "The attached tmux session changed.")
        for session in ["original", "visible"] {
            let panes = AccountCommandRunner.runProcess(
                executable: tmuxPath,
                arguments: [
                    "-L", socketName, "list-panes", "-t", "=\(session):",
                    "-F", "#{pane_id}",
                ],
                timeout: 5
            )
            #expect(panes.stdout.split(whereSeparator: \.isNewline).count == 1)
        }
    }
}
