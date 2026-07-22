import Foundation
import Darwin
import GhosthubWorkspace

struct ProcessSamplingState: Sendable {
    var previousTotalCPUTimeByPID: [pid_t: UInt64] = [:]
    var previousSnapshotAt: Date?
}

struct ProcessSampleResult: Sendable {
    var snapshot: ProcessTreeSnapshot?
    var nextState: ProcessSamplingState
}

struct ProcessSnapshotEntry: Sendable {
    var parentPID: pid_t
    var cpuPercent: Double
    var residentMB: Int
}

struct ProcessTreeSnapshot: Sendable {
    var capturedAt: Date
    var aggregate: WorkspaceResourceSample
    var processes: [WorkspaceProcessResource]
}

struct WorkspaceProcessRoot: Sendable {
    var pid: pid_t
    var worktreeID: UUID?
    var leafID: UUID?
}

final class ProcessResourceMonitor {
    private struct ProcessUsage {
        var cpuPercent: Double
        var residentMB: Int
        var totalCPUTimeNanos: UInt64?
    }

    private let rootPIDProvider: () -> pid_t
    private let childProcessProvider: (pid_t) -> [pid_t]?
    private let processUsageProvider: (pid_t) -> (totalCPUTimeNanos: UInt64, residentMB: Int)?
    private let processWorkingDirectoryProvider: (pid_t) -> String?
    private let processExecutableNameProvider: (pid_t) -> String?
    private let processSnapshotProvider: () -> [pid_t: ProcessSnapshotEntry]?
    private let directStateLock = NSLock()
    private var directSamplingState = ProcessSamplingState()

    init(
        rootPIDProvider: @escaping () -> pid_t = { getpid() },
        childProcessProvider: @escaping (pid_t) -> [pid_t]? = { _ in nil },
        processUsageProvider: @escaping (pid_t)
            -> (totalCPUTimeNanos: UInt64, residentMB: Int)? = { _ in nil },
        processWorkingDirectoryProvider: @escaping (pid_t) -> String? = { _ in nil },
        processExecutableNameProvider: @escaping (pid_t) -> String? = { _ in nil },
        processSnapshotProvider: @escaping () -> [pid_t: ProcessSnapshotEntry]? = { nil }
    ) {
        self.rootPIDProvider = rootPIDProvider
        self.childProcessProvider = childProcessProvider
        self.processUsageProvider = processUsageProvider
        self.processWorkingDirectoryProvider = processWorkingDirectoryProvider
        self.processExecutableNameProvider = processExecutableNameProvider
        self.processSnapshotProvider = processSnapshotProvider
    }

    func sample(
        roots: [WorkspaceProcessRoot] = [],
        now: Date = .now,
        state: ProcessSamplingState = ProcessSamplingState()
    ) -> ProcessSampleResult {
        var cachedProcessSnapshot: [pid_t: ProcessSnapshotEntry]?
        var cachedSnapshotChildMap: [pid_t: [pid_t]] = [:]
        var didAttemptProcessSnapshotLoad = false

        func processSnapshot() -> [pid_t: ProcessSnapshotEntry]? {
            guard !didAttemptProcessSnapshotLoad else {
                return cachedProcessSnapshot
            }
            didAttemptProcessSnapshotLoad = true
            cachedProcessSnapshot = processSnapshotProvider()
                ?? loadProcessSnapshot()
            cachedSnapshotChildMap = snapshotChildMap(from: cachedProcessSnapshot)
            return cachedProcessSnapshot
        }

        let processIDs = allProcessIDs(
            roots: roots,
            snapshotChildMapProvider: {
                _ = processSnapshot()
                return cachedSnapshotChildMap
            }
        )
        guard !processIDs.isEmpty else {
            return ProcessSampleResult(
                snapshot: nil,
                nextState: state
            )
        }

        let elapsed = state.previousSnapshotAt.map {
            now.timeIntervalSince($0)
        } ?? 0

        let pidToAttribution = buildPIDToAttribution(
            roots: roots,
            snapshotChildMapProvider: {
                _ = processSnapshot()
                return cachedSnapshotChildMap
            }
        )
        let managedPIDs = Set(pidToAttribution.keys)

        var processes: [WorkspaceProcessResource] = []
        var aggregateCPUPercent = 0.0
        var aggregateResidentMB = 0
        var aggregateProcessCount = 0
        var currentTotalCPUTimeByPID: [pid_t: UInt64] = [:]

        for pid in processIDs {
            guard let usage = processUsage(
                for: pid,
                elapsed: elapsed,
                state: state,
                processSnapshotProvider: {
                    processSnapshot()
                }
            ) else {
                continue
            }

            if let totalCPUTimeNanos = usage.totalCPUTimeNanos {
                currentTotalCPUTimeByPID[pid] = totalCPUTimeNanos
            }

            let sample = WorkspaceResourceSample(
                cpuPercent: usage.cpuPercent,
                residentMB: usage.residentMB,
                processCount: 1
            )
            let executableName = processExecutableName(for: pid)
            let workingDirectory = managedPIDs.contains(pid)
                ? processWorkingDirectory(for: pid)
                : nil
            let attribution = pidToAttribution[pid]
            processes.append(
                WorkspaceProcessResource(
                    worktreeID: attribution?.worktreeID,
                    leafID: attribution?.leafID,
                    workingDirectory: workingDirectory,
                    executableName: executableName,
                    recognizedAgent: WorkspaceKnownAgent.recognize(
                        executableName: executableName
                    ),
                    sample: sample
                )
            )

            aggregateCPUPercent += usage.cpuPercent
            aggregateResidentMB += usage.residentMB
            aggregateProcessCount += 1
        }

        return ProcessSampleResult(
            snapshot: ProcessTreeSnapshot(
                capturedAt: now,
                aggregate: WorkspaceResourceSample(
                    cpuPercent: aggregateCPUPercent,
                    residentMB: aggregateResidentMB,
                    processCount: aggregateProcessCount
                ),
                processes: processes
            ),
            nextState: ProcessSamplingState(
                previousTotalCPUTimeByPID: currentTotalCPUTimeByPID,
                previousSnapshotAt: now
            )
        )
    }

    func sample(
        roots: [WorkspaceProcessRoot] = [],
        now: Date = .now
    ) -> ProcessTreeSnapshot? {
        directStateLock.lock()
        let currentState = directSamplingState
        directStateLock.unlock()

        let result = sample(
            roots: roots,
            now: now,
            state: currentState
        )

        directStateLock.lock()
        directSamplingState = result.nextState
        directStateLock.unlock()
        return result.snapshot
    }

    private struct ProcessAttribution {
        var worktreeID: UUID?
        var leafID: UUID?

        var specificity: Int {
            if leafID != nil {
                return 2
            }
            if worktreeID != nil {
                return 1
            }
            return 0
        }
    }

    private func buildPIDToAttribution(
        roots: [WorkspaceProcessRoot],
        snapshotChildMapProvider: () -> [pid_t: [pid_t]]
    ) -> [pid_t: ProcessAttribution] {
        guard !roots.isEmpty else { return [:] }

        var result: [pid_t: ProcessAttribution] = [:]

        for root in orderedRootsBySpecificity(roots) {
            let subtree = processTree(
                rootPID: root.pid,
                allowSnapshotMerge: true,
                snapshotChildMapProvider: snapshotChildMapProvider
            )
            let attribution = ProcessAttribution(
                worktreeID: root.worktreeID,
                leafID: root.leafID
            )
            for pid in subtree {
                let existing = result[pid]
                if shouldReplaceAttribution(
                    existing,
                    with: attribution
                ) {
                    result[pid] = attribution
                }
            }
        }
        return result
    }

    private func orderedRootsBySpecificity(
        _ roots: [WorkspaceProcessRoot]
    ) -> [WorkspaceProcessRoot] {
        roots.sorted { lhs, rhs in
            let leftAttribution = ProcessAttribution(
                worktreeID: lhs.worktreeID,
                leafID: lhs.leafID
            )
            let rightAttribution = ProcessAttribution(
                worktreeID: rhs.worktreeID,
                leafID: rhs.leafID
            )
            if leftAttribution.specificity != rightAttribution.specificity {
                return leftAttribution.specificity < rightAttribution.specificity
            }
            if lhs.pid != rhs.pid {
                return lhs.pid < rhs.pid
            }
            if lhs.worktreeID != rhs.worktreeID {
                return (lhs.worktreeID?.uuidString ?? "")
                    < (rhs.worktreeID?.uuidString ?? "")
            }
            return (lhs.leafID?.uuidString ?? "")
                < (rhs.leafID?.uuidString ?? "")
        }
    }

    private func shouldReplaceAttribution(
        _ existing: ProcessAttribution?,
        with incoming: ProcessAttribution
    ) -> Bool {
        guard let existing else {
            return true
        }
        return incoming.specificity > existing.specificity
    }

    private func allProcessIDs(
        roots: [WorkspaceProcessRoot],
        snapshotChildMapProvider: () -> [pid_t: [pid_t]]
    ) -> [pid_t] {
        var ordered: [pid_t] = []
        var seen = Set<pid_t>()
        let monitorRootPID = rootPIDProvider()

        func appendTree(rootPID: pid_t) {
            for pid in processTree(
                rootPID: rootPID,
                allowSnapshotMerge: rootPID != monitorRootPID,
                snapshotChildMapProvider: snapshotChildMapProvider
            ) where seen.insert(pid).inserted {
                ordered.append(pid)
            }
        }

        appendTree(rootPID: monitorRootPID)
        for root in roots {
            appendTree(rootPID: root.pid)
        }

        return ordered
    }

    private func processTree(
        rootPID: pid_t,
        allowSnapshotMerge: Bool,
        snapshotChildMapProvider: () -> [pid_t: [pid_t]]
    ) -> [pid_t] {
        var discovered: [pid_t] = []
        var queue = [rootPID]
        var index = 0
        var seen = Set<pid_t>()

        while index < queue.count {
            let pid = queue[index]
            index += 1
            guard seen.insert(pid).inserted else {
                continue
            }
            discovered.append(pid)

            let injectedChildren = childProcessProvider(pid)
            let directChildren = injectedChildren
                ?? childProcesses(of: pid)
            let childPIDs: Set<pid_t>
            if injectedChildren == nil, directChildren.isEmpty {
                childPIDs = Set(snapshotChildMapProvider()[pid] ?? [])
            } else if let injectedChildren {
                if allowSnapshotMerge {
                    childPIDs = Set(injectedChildren)
                        .union(snapshotChildMapProvider()[pid] ?? [])
                } else {
                    childPIDs = Set(injectedChildren)
                }
            } else if allowSnapshotMerge {
                childPIDs = Set(directChildren)
                    .union(snapshotChildMapProvider()[pid] ?? [])
            } else {
                childPIDs = Set(directChildren)
            }
            for childPID in childPIDs {
                queue.append(childPID)
            }
        }

        return discovered
    }

    private func childProcesses(of parentPID: pid_t) -> [pid_t] {
        var capacity = 16

        while true {
            var buffer = Array(repeating: pid_t(0), count: capacity)
            let byteCount = proc_listchildpids(
                parentPID,
                &buffer,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )

            if byteCount <= 0 {
                return []
            }

            let count = Int(byteCount) / MemoryLayout<pid_t>.size
            if count == 0 {
                return []
            }
            if count < capacity {
                return Array(buffer.prefix(count)).filter { $0 > 0 }
            }

            capacity *= 2
        }
    }

    private func processUsage(
        for pid: pid_t,
        elapsed: TimeInterval,
        state: ProcessSamplingState,
        processSnapshotProvider: () -> [pid_t: ProcessSnapshotEntry]?
    ) -> ProcessUsage? {
        if let external = processUsageProvider(pid) {
            return makeProcessUsage(
                totalCPUTimeNanos: external.totalCPUTimeNanos,
                residentMB: external.residentMB,
                elapsed: elapsed,
                state: state,
                pid: pid
            )
        }
        if let usage = taskInfoUsage(
            for: pid,
            elapsed: elapsed,
            state: state
        ) {
            return usage
        }
        if let snapshotEntry = processSnapshotProvider()?[pid] {
            return ProcessUsage(
                cpuPercent: snapshotEntry.cpuPercent,
                residentMB: snapshotEntry.residentMB,
                totalCPUTimeNanos: nil
            )
        }
        return nil
    }

    private func taskInfoUsage(
        for pid: pid_t,
        elapsed: TimeInterval,
        state: ProcessSamplingState
    ) -> ProcessUsage? {
        var info = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = proc_pidinfo(
            pid,
            PROC_PIDTASKINFO,
            0,
            &info,
            expectedSize
        )

        guard result == expectedSize else {
            return nil
        }

        let totalCPUTimeNanos = info.pti_total_user + info.pti_total_system
        let residentMB = Int(info.pti_resident_size / 1_048_576)
        return makeProcessUsage(
            totalCPUTimeNanos: totalCPUTimeNanos,
            residentMB: residentMB,
            elapsed: elapsed,
            state: state,
            pid: pid
        )
    }

    private func makeProcessUsage(
        totalCPUTimeNanos: UInt64,
        residentMB: Int,
        elapsed: TimeInterval,
        state: ProcessSamplingState,
        pid: pid_t
    ) -> ProcessUsage {
        let cpuPercent: Double
        if let previousCPUTime = state.previousTotalCPUTimeByPID[pid],
           elapsed > 0 {
            let delta = totalCPUTimeNanos >= previousCPUTime
                ? totalCPUTimeNanos - previousCPUTime
                : 0
            cpuPercent = (Double(delta) / (elapsed * 1_000_000_000))
                * 100
        } else {
            cpuPercent = 0
        }
        return ProcessUsage(
            cpuPercent: cpuPercent,
            residentMB: residentMB,
            totalCPUTimeNanos: totalCPUTimeNanos
        )
    }

    private func processWorkingDirectory(for pid: pid_t) -> String? {
        if let external = processWorkingDirectoryProvider(pid) {
            return external
        }
        var info = proc_vnodepathinfo()
        let expectedSize = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let result = proc_pidinfo(
            pid,
            PROC_PIDVNODEPATHINFO,
            0,
            &info,
            expectedSize
        )

        guard result == expectedSize else {
            return nil
        }

        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cString in
                let path = String(cString: cString)
                return path.isEmpty ? nil : path
            }
        }
    }

    private func processExecutableName(for pid: pid_t) -> String? {
        if let external = processExecutableNameProvider(pid) {
            let executableName = external.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return executableName.isEmpty ? nil : executableName
        }

        var buffer = Array(repeating: CChar(0), count: Int(MAXPATHLEN))
        let result = proc_name(
            pid,
            &buffer,
            UInt32(buffer.count)
        )

        guard result > 0 else {
            return nil
        }

        let executableName = String(
            decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return executableName.isEmpty ? nil : executableName
    }

    private func snapshotChildMap(
        from processSnapshot: [pid_t: ProcessSnapshotEntry]?
    ) -> [pid_t: [pid_t]] {
        guard let processSnapshot else {
            return [:]
        }

        var childMap: [pid_t: [pid_t]] = [:]
        childMap.reserveCapacity(processSnapshot.count)
        for (pid, entry) in processSnapshot {
            childMap[entry.parentPID, default: []].append(pid)
        }
        return childMap
    }

    private func loadProcessSnapshot() -> [pid_t: ProcessSnapshotEntry]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,%cpu=,rss="]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        var result: [pid_t: ProcessSnapshotEntry] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 4,
                  let pid = pid_t(parts[0]),
                  let parentPID = pid_t(parts[1]),
                  let cpuPercent = Double(parts[2]),
                  let residentKB = Int(parts[3])
            else {
                continue
            }

            result[pid] = ProcessSnapshotEntry(
                parentPID: parentPID,
                cpuPercent: cpuPercent,
                residentMB: max(residentKB / 1024, 0)
            )
        }

        return result.isEmpty ? nil : result
    }
}
