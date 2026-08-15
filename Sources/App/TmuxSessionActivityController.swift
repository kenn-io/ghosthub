@preconcurrency import Combine
import Foundation
import GhosthubTransport
import GhosthubTmux
import GhosthubUI

@MainActor
final class TmuxSessionActivityController: ObservableObject {
    typealias Sampler = @Sendable (
        WorkspaceTmuxSessionSelection,
        TmuxSessionIdentity,
        CommandHost
    ) async -> TmuxSessionActivityProbeResult

    private struct Entry: Sendable {
        var selection: WorkspaceTmuxSessionSelection
        var identity: TmuxSessionIdentity
        var host: CommandHost
        var paneID: String?
        var dimensions: String?
        var fingerprint: String?
        var lastSampledAt: Date?
        var lastChangedAt: Date?
        var nextSampleAt: Date
    }

    private struct InFlightSample {
        let requestID: UUID
        let task: Task<Void, Never>
    }

    @Published private(set) var workingSessionIDs: Set<String> = []
    @Published private(set) var windowCountsBySessionID: [String: Int] = [:]

    /// Session IDs currently enrolled for warm-activity sampling. Warm
    /// enrollment completes asynchronously after identity verification, so
    /// callers that need to sample deterministically wait on this set.
    var warmSessionIDs: Set<String> { Set(entries.keys) }

    private let sampler: Sampler
    private let activityDuration: TimeInterval
    private let workingSampleInterval: TimeInterval
    private let quietSampleInterval: TimeInterval
    private let failureSampleInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let automaticallyPolls: Bool
    private var entries: [String: Entry] = [:]
    private var inFlightSamples: [String: InFlightSample] = [:]
    private var pollingTask: Task<Void, Never>?

    init(
        sampler: Sampler? = nil,
        activityDuration: TimeInterval = 30,
        workingSampleInterval: TimeInterval = 5,
        quietSampleInterval: TimeInterval = 20,
        failureSampleInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { .now },
        automaticallyPolls: Bool = true
    ) {
        let probe = TmuxSessionActivityProbe()
        self.sampler = sampler ?? { selection, identity, host in
            await probe.sample(
                selection,
                expectedIdentity: identity,
                on: host
            )
        }
        self.activityDuration = activityDuration
        self.workingSampleInterval = workingSampleInterval
        self.quietSampleInterval = quietSampleInterval
        self.failureSampleInterval = failureSampleInterval
        self.now = now
        self.automaticallyPolls = automaticallyPolls
    }

    deinit {
        pollingTask?.cancel()
        inFlightSamples.values.forEach { $0.task.cancel() }
    }

    func warm(
        _ selection: WorkspaceTmuxSessionSelection,
        identity: TmuxSessionIdentity,
        on host: CommandHost,
        at date: Date = .now
    ) {
        let id = selection.id
        if var entry = entries[id],
           entry.identity == identity,
           entry.host == host {
            entry.selection = selection
            entry.host = host
            entry.nextSampleAt = min(entry.nextSampleAt, date)
            entries[id] = entry
        } else {
            inFlightSamples.removeValue(forKey: id)?.task.cancel()
            setWorking(false, sessionID: id)
            setWindowCount(nil, sessionID: id)
            entries[id] = Entry(
                selection: selection,
                identity: identity,
                host: host,
                paneID: nil,
                nextSampleAt: date
            )
        }
        startPollingIfNeeded()
    }

    func reconcile(endpointsByHostID: [UUID: CommandHost]) {
        let sessionIDs = entries.compactMap { id, entry in
            endpointsByHostID[entry.selection.hostID] != entry.host
                ? id
                : nil
        }
        invalidate(sessionIDs: sessionIDs)
    }

    func sampleWarmSessions(at date: Date? = nil) async {
        let tasks = scheduleWarmSessionSamples(at: date)
        for task in tasks {
            await task.value
        }
    }

    private func scheduleWarmSessionSamples(
        at date: Date? = nil
    ) -> [Task<Void, Never>] {
        let startedAt = date ?? now()
        for (id, entry) in entries {
            if !isWorking(entry, at: startedAt) {
                setWorking(false, sessionID: id)
            }
        }
        let dueEntries = entries.compactMap { id, entry in
            entry.nextSampleAt <= startedAt
                && inFlightSamples[id] == nil ? (id, entry) : nil
        }
        let sampler = sampler
        let now = now
        return dueEntries.map { id, entry in
            let requestID = UUID()
            let task = Task { [weak self] in
                let result = await sampler(
                    entry.selection,
                    entry.identity,
                    entry.host
                )
                guard let self else { return }
                applySample(
                    result,
                    sessionID: id,
                    identity: entry.identity,
                    host: entry.host,
                    requestID: requestID,
                    startedAt: startedAt,
                    completedAt: date ?? now()
                )
            }
            inFlightSamples[id] = InFlightSample(
                requestID: requestID,
                task: task
            )
            return task
        }
    }

    private func applySample(
        _ result: TmuxSessionActivityProbeResult,
        sessionID id: String,
        identity: TmuxSessionIdentity,
        host: CommandHost,
        requestID: UUID,
        startedAt: Date,
        completedAt: Date
    ) {
        guard inFlightSamples[id]?.requestID == requestID else { return }
        inFlightSamples.removeValue(forKey: id)
        guard var entry = entries[id],
              entry.identity == identity,
              entry.host == host
        else { return }
        switch result {
        case let .sample(paneID, dimensions, fingerprint, windowCount):
            let previousIsRecent = entry.lastSampledAt.map { sampledAt in
                startedAt.timeIntervalSince(sampledAt) < activityDuration
            } ?? false
            if entry.paneID == paneID,
               entry.dimensions == dimensions,
               previousIsRecent,
               let previous = entry.fingerprint,
               previous != fingerprint {
                entry.lastChangedAt = completedAt
            }
            entry.paneID = paneID
            entry.dimensions = dimensions
            entry.fingerprint = fingerprint
            entry.lastSampledAt = completedAt
            let isWorking = isWorking(entry, at: completedAt)
            setWorking(isWorking, sessionID: id)
            entry.nextSampleAt = completedAt.addingTimeInterval(
                isWorking
                    ? workingSampleInterval
                    : quietSampleInterval
            )
            entries[id] = entry
            if let windowCount {
                setWindowCount(windowCount, sessionID: id)
            }
        case .ended:
            entries.removeValue(forKey: id)
            setWorking(false, sessionID: id)
            setWindowCount(nil, sessionID: id)
        case .unavailable:
            let isWorking = isWorking(entry, at: completedAt)
            setWorking(isWorking, sessionID: id)
            let retryAt = completedAt.addingTimeInterval(
                failureSampleInterval
            )
            if let lastChangedAt = entry.lastChangedAt,
               isWorking {
                entry.nextSampleAt = min(
                    retryAt,
                    lastChangedAt.addingTimeInterval(activityDuration)
                )
            } else {
                entry.nextSampleAt = retryAt
            }
            entries[id] = entry
        }
    }

    private func isWorking(_ entry: Entry, at date: Date) -> Bool {
        guard let lastChangedAt = entry.lastChangedAt else { return false }
        return date.timeIntervalSince(lastChangedAt) < activityDuration
    }

    private func invalidate(sessionIDs: [String]) {
        for id in sessionIDs {
            inFlightSamples.removeValue(forKey: id)?.task.cancel()
            entries.removeValue(forKey: id)
            setWorking(false, sessionID: id)
            setWindowCount(nil, sessionID: id)
        }
    }

    private func setWorking(_ isWorking: Bool, sessionID: String) {
        if isWorking {
            guard !workingSessionIDs.contains(sessionID) else { return }
            workingSessionIDs.insert(sessionID)
        } else {
            guard workingSessionIDs.contains(sessionID) else { return }
            workingSessionIDs.remove(sessionID)
        }
    }

    private func setWindowCount(_ count: Int?, sessionID: String) {
        guard windowCountsBySessionID[sessionID] != count else { return }
        windowCountsBySessionID[sessionID] = count
    }

    private func startPollingIfNeeded() {
        guard automaticallyPolls, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                _ = scheduleWarmSessionSamples()
            }
        }
    }
}
