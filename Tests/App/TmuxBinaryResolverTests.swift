import Darwin
import Foundation
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("TmuxBinaryResolver")
struct TmuxBinaryResolverTests {
    @Test("tmux subprocesses do not inherit a launcher session")
    func stripsLauncherTmuxEnvironment() {
        let sanitized = TmuxBinaryResolver.sanitizedProcessEnvironment([
            "PATH": "/usr/bin",
            "TMUX": "/tmp/tmux-501/default,1,0",
            "TMUX_PANE": "%3",
        ])

        #expect(sanitized == ["PATH": "/usr/bin"])
    }

    @Test("parses the resolved path from shell output")
    func parsesPath() throws {
        let resolver = TmuxBinaryResolver(processRunner: { _, command in
            #expect(command.contains("command -v tmux"))
            #expect(command.contains("-V"))
            #expect(command.hasPrefix("ghosthub_tmux_path="))
            return (
                status: 0,
                stdout: "/opt/homebrew/bin/tmux\ntmux 3.6a\n"
            )
        })
        #expect(try resolver.resolveTmuxPath().get() == "/opt/homebrew/bin/tmux")
    }

    @Test("account shell initializes PATH without interpreting probe syntax")
    func supportsNonPOSIXLoginShells() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-login-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let tmux = directory.appendingPathComponent("tmux")
        try "#!/bin/sh\nprintf 'tmux 3.6a\\n'\n".write(
            to: tmux, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tmux.path
        )

        let shell = directory.appendingPathComponent("account-shell")
        try """
        #!/bin/sh
        case "$2" in
          "exec /bin/sh -c "*) ;;
          *) exit 97 ;;
        esac
        PATH=\(shellQuotedCommandArgument(directory.path)):/usr/bin:/bin
        export PATH
        exec /bin/sh -c "$2"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )

        let resolver = TmuxBinaryResolver(
            loginShellProvider: { shell.path }
        )

        #expect(resolver.resolveTmuxPath() == .success(tmux.path))
    }

    @Test("rejects unsupported tmux versions")
    func rejectsOldVersion() {
        let resolver = TmuxBinaryResolver(processRunner: { _, _ in
            (status: 0, stdout: "/usr/bin/tmux\ntmux 3.1c\n")
        })
        #expect(
            resolver.resolveTmuxPath()
                == .failure(.unsupportedVersion(found: "tmux 3.1c"))
        )
    }

    @Test("remote resolution tolerates login banners and returns an absolute path")
    func resolvesRemoteLoginShellPath() throws {
        let host = SSHHostInfo(user: "wesm", hostname: "build-box", port: 2222)
        let resolver = TmuxBinaryResolver(remoteProcessRunner: { received, command in
            #expect(received == host)
            #expect(command.contains("command -v tmux"))
            return (
                status: 0,
                stdout: "welcome\n/usr/local/bin/tmux\ntmux 3.2a\n"
            )
        })

        #expect(
            try resolver.resolveTmuxPath(on: host).get()
                == "/usr/local/bin/tmux"
        )
    }

    @Test("discovers every local tmux session without control-mode attachment")
    func discoversLocalSessions() throws {
        let resolver = TmuxBinaryResolver(processRunner: { _, command in
            #expect(command.contains("list-sessions"))
            #expect(command.contains("#{session_name}"))
            #expect(!command.contains("-CC"))
            #expect(!command.contains("; status="))
            #expect(command.hasPrefix("ghosthub_tmux_path="))
            #expect(command.contains("ghosthub_tmux_status"))
            return (
                status: 0,
                stdout: """
                /opt/homebrew/bin/tmux
                tmux 3.7b
                GHOSTHUB_TMUX_SESSION\t2\t1783344091\t\tdocbank
                GHOSTHUB_TMUX_SESSION\t4\t1783344092\towner-token\tGhosthub\twork

                """
            )
        })

        #expect(
            try resolver.discoverSessions().get() == [
                DiscoveredTmuxSession(
                    name: "docbank", windowCount: 2,
                    createdAt: "1783344091", managed: false
                ),
                DiscoveredTmuxSession(
                    name: "Ghosthub\twork", windowCount: 4,
                    createdAt: "1783344092", managed: true
                ),
            ]
        )
    }

    @Test("real zsh login shell discovers the current tmux server")
    func realZshLoginShellDiscoversCurrentServer() throws {
        guard ProcessInfo.processInfo.environment[
            "GHOSTHUB_RUN_LIVE_INTEGRATION_TESTS"
        ] == "1" else { return }
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else {
            return
        }
        let expected = TmuxBinaryResolver.runLoginShell(
            shell: "/bin/zsh",
            command: "tmux list-sessions -F '#{session_name}' 2>/dev/null",
            timeout: 5
        )
        guard expected.status == 0 else { return }

        let resolver = TmuxBinaryResolver(
            loginShellProvider: { "/bin/zsh" }
        )
        let discovered = try resolver.discoverSessions().get()
        let expectedNames = Set(
            expected.stdout.split(whereSeparator: \.isNewline).map(String.init)
        )

        #expect(Set(discovered.map(\.name)) == expectedNames)
    }

    @Test("remote discovery uses the configured SSH host")
    func discoversRemoteSessions() throws {
        let host = SSHHostInfo(
            user: "wesm", hostname: "build-box", port: 2222
        )
        let resolver = TmuxBinaryResolver(
            remoteProcessRunner: { received, command in
                #expect(received == host)
                #expect(command.contains("list-sessions"))
                return (
                    status: 0,
                    stdout: """
                    /usr/local/bin/tmux
                    tmux 3.4
                    GHOSTHUB_TMUX_SESSION\t3\t99\t\tremote-work

                    """
                )
            }
        )

        #expect(
            try resolver.discoverSessions(on: host).get()
                == [DiscoveredTmuxSession(
                    name: "remote-work", windowCount: 3,
                    createdAt: "99", managed: false
                )]
        )
    }

    @Test("a reachable tmux server with no sessions produces an empty inventory")
    func discoversEmptyServer() throws {
        let resolver = TmuxBinaryResolver(processRunner: { _, _ in
            (status: 0, stdout: "/usr/bin/tmux\ntmux 3.3a\n")
        })

        #expect(try resolver.discoverSessions().get().isEmpty)
    }

    @Test("nonzero exit maps to notFound")
    func notFound() {
        let resolver = TmuxBinaryResolver(processRunner: { _, _ in
            (status: 1, stdout: "")
        })
        guard case .failure(.notFound) = resolver.resolveTmuxPath() else {
            Issue.record("expected notFound")
            return
        }
    }

    @Test("real login shell resolves tmux on this machine")
    func realResolution() throws {
        let resolver = TmuxBinaryResolver()
        switch resolver.resolveTmuxPath() {
        case let .success(path):
            #expect(FileManager.default.isExecutableFile(atPath: path))
        case .failure:
            // Only acceptable if tmux genuinely isn't installed.
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/bin/sh")
            probe.arguments = ["-lc", "command -v tmux"]
            try probe.run()
            probe.waitUntilExit()
            #expect(probe.terminationStatus != 0, "tmux exists but resolver failed")
        }
    }

    @Test("a hanging login-shell probe is terminated at its deadline")
    func hangingProbeTimesOut() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("hanging-shell")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(
            to: shell, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let resolver = TmuxBinaryResolver(
            processTimeout: 0.05,
            loginShellProvider: { shell.path }
        )
        let started = Date()

        #expect(
            resolver.resolveTmuxPath()
                == .failure(.probeTimedOut(shell: shell.path))
        )
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("cancelling a login-shell probe terminates it promptly")
    func hangingProbeCancels() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("hanging-shell")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(
            to: shell, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let resolver = TmuxBinaryResolver(
            processTimeout: 5,
            loginShellProvider: { shell.path }
        )
        let task = Task.detached { resolver.resolveTmuxPath() }
        try await Task.sleep(for: .milliseconds(50))
        let started = Date()
        task.cancel()

        #expect(
            await task.value
                == .failure(.probeCancelled(shell: shell.path))
        )
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("a background descendant cannot hold probe stdout open")
    func backgroundDescendantTimesOutAndIsKilled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("background-shell")
        let childPIDFile = directory.appendingPathComponent("child-pid")
        try """
        #!/bin/sh
        /bin/sleep 10 &
        printf '%s' "$!" > \(childPIDFile.path)
        exit 1
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        // The probe kills the shell's process group on timeout, so the budget
        // must comfortably exceed process startup. At a fraction of a second a
        // loaded machine can reach the timeout before the shell has recorded
        // its child, leaving nothing to assert against.
        let processTimeout: TimeInterval = 2
        let resolver = TmuxBinaryResolver(
            processTimeout: processTimeout,
            loginShellProvider: { shell.path }
        )
        let started = Date()

        #expect(
            resolver.resolveTmuxPath()
                == .failure(.probeTimedOut(shell: shell.path))
        )
        // Well under the descendant's ten-second sleep: the probe must not
        // wait for it.
        #expect(Date().timeIntervalSince(started) < processTimeout + 3)
        let childPID = try #require(Self.recordedPID(at: childPIDFile))
        #expect(Self.waitForExit(of: childPID))
    }

    /// Reads a pid a subprocess published, tolerating the gap between the
    /// shell creating the file through redirection and writing the value.
    private static func recordedPID(
        at file: URL,
        timeout: TimeInterval = 5
    ) -> Int32? {
        poll(timeout: timeout) {
            guard let contents = try? String(
                contentsOf: file, encoding: .utf8
            ) else { return nil }
            return Int32(
                contents.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Signalling a process group does not reap its members synchronously.
    private static func waitForExit(
        of pid: Int32,
        timeout: TimeInterval = 5
    ) -> Bool {
        poll(timeout: timeout) { kill(pid, 0) != 0 ? true : nil } ?? false
    }

    private static func poll<Value>(
        timeout: TimeInterval,
        until produce: () -> Value?
    ) -> Value? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = produce() { return value }
            usleep(20_000)
        } while Date() < deadline
        return produce()
    }

    @Test("noisy startup output is drained but remains memory bounded")
    func noisyProbeOutputIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("noisy-shell")
        try """
        #!/bin/sh
        /usr/bin/yes x | /usr/bin/head -c 1100000
        exit 0
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let resolver = TmuxBinaryResolver(
            processTimeout: 2,
            loginShellProvider: { shell.path }
        )

        #expect(
            resolver.resolveTmuxPath()
                == .failure(.probeOutputExceeded(shell: shell.path))
        )
    }

    @Test("continuously readable output cannot bypass the probe budget")
    func continuouslyReadableOutputIsInterrupted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = directory.appendingPathComponent("continuous-shell")
        try """
        #!/bin/sh
        /usr/bin/yes x &
        producer=$!
        (/bin/sleep 2; /bin/kill "$producer" 2>/dev/null) &
        wait "$producer"
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let resolver = TmuxBinaryResolver(
            processTimeout: 5,
            loginShellProvider: { shell.path }
        )
        let started = Date()

        #expect(
            resolver.resolveTmuxPath()
                == .failure(.probeOutputExceeded(shell: shell.path))
        )
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("probe does not inherit unrelated descriptors")
    func probeDescriptorsAreIsolated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tmux-resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        var unrelatedDescriptors = [Int32](repeating: -1, count: 2)
        let pipeStatus = unrelatedDescriptors.withUnsafeMutableBufferPointer {
            pipe($0.baseAddress!)
        }
        try #require(pipeStatus == 0)
        let unrelatedRead = unrelatedDescriptors[0]
        let unrelatedWrite = unrelatedDescriptors[1]
        defer {
            close(unrelatedRead)
            close(unrelatedWrite)
        }
        #expect(fcntl(unrelatedRead, F_SETFD, 0) == 0)

        let shell = directory.appendingPathComponent("probe-shell")
        try """
        #!/bin/sh
        if [ -e /dev/fd/\(unrelatedRead) ]; then
          exit 42
        fi
        printf '/opt/homebrew/bin/tmux\ntmux 3.6a\n'
        """.write(to: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: shell.path
        )
        let resolver = TmuxBinaryResolver(loginShellProvider: { shell.path })

        #expect(
            resolver.resolveTmuxPath()
                == .success("/opt/homebrew/bin/tmux")
        )
    }
}

@Suite("TmuxPathCache")
struct TmuxPathCacheTests {
    /// The resolve closure is `@Sendable` (the cache resolves off the main
    /// actor), so a mutable call counter lives in a lock-free atomic box
    /// rather than a captured `var`.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    @Test("a successful resolution is cached and not re-resolved")
    func cachesSuccess() throws {
        let counter = Counter()
        let cache = TmuxPathCache {
            _ = counter.increment()
            return .success("/opt/homebrew/bin/tmux")
        }

        #expect(try cache.resolveTmuxPath().get() == "/opt/homebrew/bin/tmux")
        #expect(try cache.resolveTmuxPath().get() == "/opt/homebrew/bin/tmux")
        #expect(counter.count == 1)
    }

    @Test("a failed resolution is not cached, so a later install recovers without a restart")
    func doesNotCacheFailure() throws {
        let counter = Counter()
        let cache = TmuxPathCache {
            counter.increment() == 1
                ? .failure(.notFound(shell: "/bin/zsh"))
                : .success("/opt/homebrew/bin/tmux")
        }

        guard case .failure = cache.resolveTmuxPath() else {
            Issue.record("expected the first resolve to fail")
            return
        }
        #expect(try cache.resolveTmuxPath().get() == "/opt/homebrew/bin/tmux")
        #expect(counter.count == 2)
    }
}
