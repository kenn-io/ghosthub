import Foundation
import GhosthubTestSupport
import Testing
@testable import GhosthubApp
import GhosthubPersistence
import GhosthubWorkspace

// MARK: - Seeded Database

struct SeededWorkspace {
    let database: WorkspaceDatabase
    let hostID: UUID
    let projectID: UUID
    let referenceDate: Date
}

func seededWorkspace(
    referenceDate: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> SeededWorkspace {
    let database = try WorkspaceDatabase.inMemory()
    let hostID = UUID()
    let projectID = UUID()
    return SeededWorkspace(
        database: database,
        hostID: hostID,
        projectID: projectID,
        referenceDate: referenceDate
    )
}

// MARK: - Terminal Session Record Factory

func makeSessionRecord(
    id: UUID = UUID(),
    hostID: UUID,
    worktreeID: UUID? = nil,
    scopedKey: String,
    presetID: String? = nil,
    kind: SessionKind = .shell,
    launchMode: LaunchMode = .loginShell,
    backend: SessionBackendKind = .localPTY,
    workingDirectory: String? = nil,
    command: String? = nil,
    childPID: Int32? = nil,
    remoteLocator: String? = nil,
    isAlive: Bool = true,
    restartPolicy: RestartPolicy = .never,
    lastExitCode: Int32? = nil,
    lastOutputAt: Date? = nil,
    lastSeenInSnapshotAt: Date? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> TerminalSessionRecord {
    TerminalSessionRecord(
        id: id,
        hostID: hostID,
        worktreeID: worktreeID,
        scopedKey: scopedKey,
        presetID: presetID,
        kind: kind,
        launchMode: launchMode,
        backend: backend,
        workingDirectory: workingDirectory,
        command: command,
        childPID: childPID,
        remoteLocator: remoteLocator,
        isAlive: isAlive,
        restartPolicy: restartPolicy,
        lastExitCode: lastExitCode,
        lastOutputAt: lastOutputAt,
        lastSeenInSnapshotAt: lastSeenInSnapshotAt,
        createdAt: createdAt,
        updatedAt: updatedAt
    )
}

// MARK: - Async Polling

/// Polls an async condition until it returns true or the timeout expires.
func waitUntil(
    timeout: Duration = .seconds(5),
    pollInterval: Duration = .milliseconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(for: pollInterval)
    }
    if await condition() {
        return
    }
    Issue.record(
        "waitUntil timed out after \(timeout)",
        sourceLocation: sourceLocation
    )
}

/// Polls a MainActor-isolated condition until it returns true or the timeout expires.
@MainActor
func waitUntilMainActor(
    // Swift Testing runs suites concurrently, so a package-wide run can spend
    // several seconds scheduling other MainActor-isolated tests before this
    // condition is evaluated again.
    timeout: Duration = .seconds(10),
    pollInterval: Duration = .milliseconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @MainActor () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(for: pollInterval)
    }
    if await condition() {
        return
    }
    Issue.record(
        "waitUntilMainActor timed out after \(timeout)",
        sourceLocation: sourceLocation
    )
}

// MARK: - Concurrency Primitives

final class DeferredExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedWork: [@Sendable () -> Void] = []

    var queuedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedWork.count
    }

    func schedule(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        queuedWork.append(work)
        lock.unlock()
    }

    func runAll() {
        while let next = dequeue() {
            next()
        }
    }

    private func dequeue() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard !queuedWork.isEmpty else {
            return nil
        }
        return queuedWork.removeFirst()
    }
}

final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func load() -> T {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ newValue: T) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func withLock(_ update: (inout T) -> Void) {
        lock.lock()
        update(&value)
        lock.unlock()
    }
}

// MARK: - Domain Model Fixtures

extension WorkspaceSnapshot {
    static func singleWorktreeFixture(
        hostID: UUID = UUID(),
        projectID: UUID = UUID(),
        worktreeID: UUID = UUID(),
        isPrimary: Bool = true,
        checksStatus: ChecksStatus? = nil
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            hosts: [
                .fixture(id: hostID),
            ],
            projects: [
                .fixture(
                    id: projectID, hostID: hostID
                ),
            ],
            worktrees: [
                .fixture(
                    id: worktreeID,
                    hostID: hostID,
                    projectID: projectID,
                    isPrimary: isPrimary,
                    checksStatus: checksStatus
                ),
            ]
        )
    }
}
