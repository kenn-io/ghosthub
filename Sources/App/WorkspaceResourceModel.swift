import Foundation
import GhosthubWorkspace

struct WorkspaceHostResourcePatch: Equatable, Sendable {
    var hostKey: String
    var cpuPercent: Double
    var residentMB: Int
}

enum WorkspaceResourceModel {
    static func hostResourcePatch(
        snapshot: WorkspaceSnapshot,
        summary: WorkspaceResourceSummary
    ) -> WorkspaceHostResourcePatch? {
        guard let aggregate = summary.aggregate else {
            return nil
        }
        guard let host = snapshot.hosts.first(where: {
            $0.kind == .selfHost
        }) else {
            return nil
        }
        return WorkspaceHostResourcePatch(
            hostKey: WorkspaceKeyResolver.hostKey(for: host),
            cpuPercent: aggregate.cpuPercent,
            residentMB: aggregate.residentMB
        )
    }

    static func summary(
        snapshot: WorkspaceSnapshot,
        selectedHostID: UUID,
        aggregate: WorkspaceResourceSample?,
        processes: [WorkspaceProcessResource],
        lastUpdatedAt: Date?,
        refreshIntervalSeconds: Int
    ) -> WorkspaceResourceSummary {
        let visibleWorktrees = snapshot.worktrees
            .filter { $0.hostID == selectedHostID }
            .sorted { lhs, rhs in
                lhs.path.count > rhs.path.count
            }

        var worktreeSamples: [UUID: WorkspaceResourceSample] = [:]
        var attributedResidentMB = 0
        var trackedProcessCount = 0

        let worktreeIDSet = Set(visibleWorktrees.map(\.id))

        for process in processes {
            trackedProcessCount += process.sample.processCount

            let worktree: WorktreeSummary?
            if let wID = process.worktreeID, worktreeIDSet.contains(wID) {
                worktree = visibleWorktrees.first { $0.id == wID }
            } else if let workingDirectory = normalizedPath(
                process.workingDirectory
            ) {
                worktree = visibleWorktrees.first {
                    path(
                        workingDirectory,
                        matchesWorktreeRoot: normalizedPath($0.path)
                    )
                }
            } else {
                worktree = nil
            }

            guard let worktree else {
                continue
            }

            var current =
                worktreeSamples[worktree.id]
                    ?? WorkspaceResourceSample(
                        cpuPercent: 0,
                        residentMB: 0,
                        processCount: 0
                    )
            current.cpuPercent += process.sample.cpuPercent
            current.residentMB += process.sample.residentMB
            current.processCount += process.sample.processCount
            worktreeSamples[worktree.id] = current
            attributedResidentMB += process.sample.residentMB
        }

        let topEntries: [WorkspaceMemoryAnalyticsEntry] = visibleWorktrees
            .compactMap { worktree in
                guard let sample = worktreeSamples[worktree.id] else {
                    return nil
                }
                return WorkspaceMemoryAnalyticsEntry(
                    worktreeID: worktree.id,
                    branch: worktree.branch,
                    residentMB: sample.residentMB,
                    cpuPercent: sample.cpuPercent
                )
            }
            .sorted {
                if $0.residentMB == $1.residentMB {
                    return $0.cpuPercent > $1.cpuPercent
                }
                return $0.residentMB > $1.residentMB
            }

        return WorkspaceResourceSummary(
            aggregate: aggregate,
            worktreeSamples: worktreeSamples,
            analytics: WorkspaceMemoryAnalytics(
                visibleWorktreeResidentMB:
                worktreeSamples.values.reduce(0) {
                    $0 + $1.residentMB
                },
                unattributedResidentMB:
                max(
                    (aggregate?.residentMB ?? 0) - attributedResidentMB,
                    0
                ),
                totalTrackedProcesses: trackedProcessCount,
                topEntries: Array(topEntries.prefix(5)),
                lastUpdatedAt: lastUpdatedAt,
                refreshIntervalSeconds: refreshIntervalSeconds
            )
        )
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .path
    }

    private static func path(
        _ workingDirectory: String,
        matchesWorktreeRoot worktreeRoot: String?
    ) -> Bool {
        guard let worktreeRoot else {
            return false
        }

        if workingDirectory == worktreeRoot {
            return true
        }

        return workingDirectory.hasPrefix(worktreeRoot + "/")
    }
}

enum WorkspacePaneResourceModel {
    static func samples(
        selectedWorktreeID: UUID?,
        selectedWorktreePath: String?,
        processes: [WorkspaceProcessResource]
    ) -> [UUID: WorkspaceResourceSample] {
        guard let selectedWorktreeID else {
            return [:]
        }

        let normalizedWorktreePath = normalizedPath(selectedWorktreePath)
        var samples: [UUID: WorkspaceResourceSample] = [:]

        for process in processes {
            guard let leafID = process.leafID else {
                continue
            }
            guard belongsToSelectedWorktree(
                process: process,
                selectedWorktreeID: selectedWorktreeID,
                selectedWorktreePath: normalizedWorktreePath
            ) else {
                continue
            }

            var current = samples[leafID] ?? WorkspaceResourceSample(
                cpuPercent: 0,
                residentMB: 0,
                processCount: 0
            )
            current.cpuPercent += process.sample.cpuPercent
            current.residentMB += process.sample.residentMB
            current.processCount += process.sample.processCount
            samples[leafID] = current
        }

        return samples
    }

    private static func belongsToSelectedWorktree(
        process: WorkspaceProcessResource,
        selectedWorktreeID: UUID,
        selectedWorktreePath: String?
    ) -> Bool {
        if process.worktreeID == selectedWorktreeID {
            return true
        }
        guard process.worktreeID == nil,
              let workingDirectory = normalizedPath(process.workingDirectory),
              let selectedWorktreePath
        else {
            return false
        }

        if workingDirectory == selectedWorktreePath {
            return true
        }

        return workingDirectory.hasPrefix(selectedWorktreePath + "/")
    }

    private static func normalizedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .path
    }
}
