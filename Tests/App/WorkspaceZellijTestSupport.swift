import Combine
import Foundation
import GhosthubPersistence
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace
import GhosthubZellij
import Synchronization
import Testing
@testable import GhosthubApp

struct ZellijValidationFailureCase:
    Sendable, CustomTestStringConvertible {
    var name: String
    var result: ZellijDiscoveryResult
    var reason: String

    var testDescription: String { name }
}

struct ZellijPendingDiscoveryFailureCase:
    Sendable, CustomTestStringConvertible {
    var name: String
    var result: ZellijDiscoveryResult

    var testDescription: String { name }
}

struct ZellijTerminalReconnectFailureCase:
    Sendable, CustomTestStringConvertible {
    var name: String
    var result: ZellijDiscoveryResult
    var reason: String

    var testDescription: String { name }
}

struct ZellijKillValidationFailureCase:
    Sendable, CustomTestStringConvertible {
    var name: String
    var result: ZellijDiscoveryResult
    var expectsUnavailable: Bool

    var testDescription: String { name }
}

final class CancellableZellijDiscoveryProbe: @unchecked Sendable {
    private struct State {
        var calls = 0
        var cancelled = false
        var released = false
    }

    private let blockingCall: Int
    private let state = Mutex(State())

    init(blockingCall: Int) {
        self.blockingCall = blockingCall
    }

    func discover(_: CommandHost) -> ZellijDiscoveryResult {
        let call = state.withLock {
            $0.calls += 1
            return $0.calls
        }
        guard call == blockingCall else {
            return .available(call > blockingCall ? ["replacement"] : [])
        }
        while !state.withLock({ $0.released }) {
            if Task.isCancelled {
                state.withLock { $0.cancelled = true }
                return .failure(.commandFailed(
                    status: -1,
                    stderr: "cancelled"
                ))
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return .available([])
    }

    var calls: Int { state.withLock { $0.calls } }
    var didCancel: Bool { state.withLock { $0.cancelled } }

    func release() {
        state.withLock { $0.released = true }
    }
}

extension WorkspaceZellijTests {
    func zellijEnvironment(
        sessions: [String]
    ) throws -> (database: WorkspaceDatabase, host: HostSummary, snapshot: WorkspaceSnapshot) {
        let database = try WorkspaceDatabase.inMemory()
        let host = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            zellijSessions: sessions.map(ZellijSessionSummary.init(name:)),
            zellijAvailable: true
        )
        return (
            database,
            host,
            WorkspaceSnapshot(hosts: [host], projects: [], worktrees: [])
        )
    }
}

enum ZellijSurfaceLaunchTestError: LocalizedError {
    case rejected

    var errorDescription: String? { "Surface launch rejected" }
}
