import Foundation
import GhosthubTestSupport
import GhosthubTransport
import Testing
@testable import GhosthubApp

/// Runs against an sshd whose `MaxSessions` is below OpenSSH's default, so
/// Ghosthub must learn the limit, spread terminals across kwt masters, and
/// keep inventory commands working beside them.
@Suite("kwt SSH session limit live integration", .serialized)
struct KwtSSHSessionLimitLiveTests {
    private static let terminalCount = 7
    private static let concurrentCommands = 12

    /// A long-lived remote session standing in for a terminal client.
    private final class RemoteSession: @unchecked Sendable {
        let connection: KwtSSHConnection
        let process: Process

        init(connection: KwtSSHConnection, process: Process) {
            self.connection = connection
            self.process = process
        }
    }

    @Test("terminals beyond one connection's session limit open another master")
    func terminalsAndCommandsStayWithinTheServerLimit() async throws {
        let processEnvironment = ProcessInfo.processInfo.environment
        guard processEnvironment["GHOSTHUB_RUN_LIVE_INTEGRATION_TESTS"] == "1",
              let destination = processEnvironment[
                  "GHOSTHUB_SSH_SESSION_LIMIT_INTEGRATION_DESTINATION"
              ], !destination.isEmpty
        else { return }
        let binary = try #require(processEnvironment["GHOSTHUB_KWT_CONTRACT_BINARY"])
        let serverLimit = try #require(Int(
            processEnvironment["GHOSTHUB_SSH_SESSION_LIMIT"] ?? ""
        ))
        let kwtHome = try #require(
            processEnvironment["GHOSTHUB_SSH_INTEGRATION_KWT_HOME"]
        )
        let environment = processEnvironment.merging(["KWT_HOME": kwtHome]) {
            _, isolated in isolated
        }
        defer {
            _ = AccountCommandRunner.runProcess(
                executable: binary,
                arguments: ["daemon", "stop"],
                timeout: 10,
                environmentOverrides: environment
            )
        }
        let host = try #require(CommandHostResolver.parseSSHDestination(destination))
        let routeClient = KwtSSHRouteClient(
            runner: { executable, arguments, timeout in
                AccountCommandRunner.runProcess(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    environmentOverrides: environment
                )
            },
            binaryPath: binary
        )
        let leaseClient = KwtSSHLeaseClient(binaryPath: binary, environment: environment)
        let lanes = KwtSSHConnectionLanes(
            primary: KwtSSHConnectionPool { route, prompt in
                try await leaseClient.acquire(route: route, prompt: prompt)
            },
            makePool: { index in
                KwtSSHConnectionPool { route, prompt in
                    try await leaseClient.acquire(
                        route: route,
                        connection: index,
                        prompt: prompt
                    )
                }
            }
        )
        let budget = SSHSessionBudget()
        let coordinator = KwtSSHAcquisitionCoordinator(
            resolve: { _ in try routeClient.resolve(host) },
            lanes: lanes,
            budget: budget
        )
        let runner = AccountCommandRunner(sessionBudget: budget)
        let request = KwtSSHDestinationRequest(destination: destination, host: host)

        var sessions: [RemoteSession] = []
        defer {
            for session in sessions where session.process.isRunning {
                session.process.terminate()
            }
        }
        for _ in 0 ..< Self.terminalCount {
            try await sessions.append(Self.openTerminal(
                coordinator: coordinator,
                request: request,
                runner: runner,
                host: host
            ))
        }

        #expect(sessions.allSatisfy { $0.process.isRunning })
        let masters = Set(sessions.compactMap {
            SSHSessionBudget.controlPath(in: $0.connection.arguments)
        })
        #expect(masters.count >= Int(
            (Double(Self.terminalCount) / Double(serverLimit)).rounded(.up)
        ))
        for master in masters {
            #expect(budget.capacity(forControlPath: master) >= 1)
            #expect(budget.openSessions(forControlPath: master) <= serverLimit)
        }

        // Inventory commands borrow connections the way production callers
        // do, so a command placed before Ghosthub learned the server limit
        // moves to a master with room.
        let commandLease = KwtSSHCommandLease { _ in
            try await coordinator.acquire(
                request: request,
                subscriberID: UUID(),
                canPresentPrompts: false,
                prompt: { _, _ in throw CancellationError() }
            )
        }
        let outputs = try await withThrowingTaskGroup(
            of: AccountCommandOutput.self
        ) { group in
            for index in 0 ..< Self.concurrentCommands {
                group.addTask {
                    try await commandLease.withArguments(on: CommandHost.ssh(host)) {
                        arguments in
                        await BlockingTask.run {
                            runner.runRemoteLoginShell(
                                host: host,
                                connectionArguments: arguments ?? [],
                                command: "sleep 0.3; printf 'probe-\(index)'",
                                timeout: 30,
                                retryPolicy: .idempotent
                            )
                        }
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let budgetState = masters.sorted().map {
            "\($0): capacity \(budget.capacity(forControlPath: $0)), "
                + "open \(budget.openSessions(forControlPath: $0))"
        }
        #expect(outputs.allSatisfy { $0.status == 0 }, "\(budgetState) \(outputs)")
        #expect(sessions.allSatisfy { $0.process.isRunning })

        for session in sessions {
            session.process.terminate()
            session.process.waitUntilExit()
            try await session.connection.release()
        }
        for master in masters {
            #expect(budget.openSessions(forControlPath: master) == 0)
        }
    }

    /// Opens one terminal the way a presentation does: acquire, probe, then
    /// start the long-lived client. A failed attempt is retried, as the
    /// reconnect supervisor would, while Ghosthub learns the server limit.
    private static func openTerminal(
        coordinator: KwtSSHAcquisitionCoordinator,
        request: KwtSSHDestinationRequest,
        runner: AccountCommandRunner,
        host: SSHHostInfo
    ) async throws -> RemoteSession {
        var failures: [String] = []
        for _ in 0 ..< 3 {
            let connection = try await coordinator.acquire(
                request: request,
                subscriberID: UUID(),
                canPresentPrompts: false,
                purpose: .terminal,
                prompt: { _, _ in throw CancellationError() }
            )
            let arguments = connection.arguments
            let probe = await Task.detached {
                runner.runRemoteLoginShell(
                    host: host,
                    connectionArguments: arguments,
                    command: "printf ready",
                    timeout: 30,
                    retryPolicy: .idempotent
                )
            }.value
            guard probe.status == 0 else {
                failures.append(probe.stderr)
                try await connection.release()
                continue
            }
            do {
                try await connection.activateSessionReservation()
            } catch {
                failures.append("activation: \(error)")
                try await connection.release()
                continue
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-T", "-o", "BatchMode=yes"] + arguments
                + ["--", host.hostname, "sleep 300"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            try await Task.sleep(for: .seconds(1))
            if process.isRunning {
                return RemoteSession(connection: connection, process: process)
            }
            let diagnostic = String(
                decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            failures.append("terminal exited \(process.terminationStatus): \(diagnostic)")
            try await connection.release()
        }
        Issue.record("terminal did not open: \(failures)")
        throw CancellationError()
    }
}
