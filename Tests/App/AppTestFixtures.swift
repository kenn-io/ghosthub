import CoreVideo
import Foundation
import GhosthubTestSupport
import GhosthubTerminal
import IOSurface
import Testing
@testable import GhosthubApp
import GhosthubPersistence
import GhosthubWorkspace

func makePreviewSnapshot(
    surfaceID: UInt32 = 1,
    seed: UInt32 = 1
) throws -> TerminalSurfaceSnapshot {
    let ioSurface = try #require(IOSurfaceCreate([
        kIOSurfaceWidth: 32,
        kIOSurfaceHeight: 20,
        kIOSurfaceBytesPerElement: 4,
        kIOSurfaceBytesPerRow: 32 * 4,
        kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
    ] as CFDictionary))
    return TerminalSurfaceSnapshot(
        frame: TerminalSurfacePreviewFrame(
            ioSurface: ioSurface,
            pixelSize: CGSize(width: 32, height: 20)
        ),
        captureToken: TerminalSurfaceCaptureToken(
            surfaceID: surfaceID,
            seed: seed
        )
    )
}

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
    // tens of seconds scheduling other MainActor-isolated tests before this
    // condition is evaluated again.
    timeout: Duration = .seconds(30),
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

func testKwtSSHAttachment(
    arguments: [String] = [],
    routeIdentity: String = "sha256:test-route",
    generation: UInt64 = 1,
    release: @escaping @Sendable () async throws -> Void = {},
    invalidate: @escaping @Sendable () async -> Void = {}
) -> KwtSSHConnection {
    KwtSSHConnection(
        arguments: arguments,
        routeIdentity: routeIdentity,
        generation: generation,
        release: release,
        invalidate: invalidate
    )
}

/// A latching gate for async test closures: `wait()` suspends until the
/// first `open()`, and every later `wait()` returns immediately.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiting = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            let pending = self.waiters
            self.waiters.removeAll()
            return pending
        }
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyOpen: Bool = lock.withLock {
                waiting = true
                if opened {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if alreadyOpen {
                continuation.resume()
            }
        }
    }

    func waitUntilWaiting() async {
        await waitUntil {
            self.lock.withLock { self.waiting }
        }
    }

    /// Returns false when the gate stays closed past `timeout`.
    func wait(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if lock.withLock({ opened }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return lock.withLock { opened }
    }
}

final class BlockingGate: @unchecked Sendable {
    private let started = LockedValue(false)
    private let release = DispatchSemaphore(value: 0)

    func block() {
        started.store(true)
        release.wait()
    }

    func waitUntilBlocked() async {
        await waitUntil { self.started.load() }
    }

    func open() {
        release.signal()
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
