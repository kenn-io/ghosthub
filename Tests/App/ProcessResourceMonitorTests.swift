import Darwin
import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

struct ProcessResourceMonitorTests {
    @Test("sample captures working directories only for managed session roots")
    func sampleCapturesWorkingDirectoryOnlyForManagedSessionRoots() {
        let worktreeID = UUID()
        let leafID = UUID()
        let worktreeRoot = "/tmp/worktrees/ghosthub"

        let monitor = ProcessResourceMonitor.fake(
            processes: [
                .app(pid: 100, residentMB: 50, children: [101]),
                .init(
                    pid: 101, residentMB: 60,
                    workingDirectory: worktreeRoot
                ),
                .init(
                    pid: 200, residentMB: 70,
                    children: [201],
                    workingDirectory: worktreeRoot
                ),
                .init(
                    pid: 201, residentMB: 80,
                    workingDirectory: "\(worktreeRoot)/src"
                ),
            ]
        )

        let snapshot = monitor.sample(
            rootPID: 200, worktreeID: worktreeID, leafID: leafID
        )

        #expect(snapshot?.processes.count == 4)
        assertSnapshotContains(
            snapshot, residentMB: 50, workingDirectory: .some(nil)
        )
        assertSnapshotContains(
            snapshot, residentMB: 60, workingDirectory: .some(nil)
        )
        assertSnapshotContains(
            snapshot,
            worktreeID: worktreeID,
            leafID: leafID,
            residentMB: 70,
            workingDirectory: worktreeRoot
        )
        assertSnapshotContains(
            snapshot,
            worktreeID: worktreeID,
            leafID: leafID,
            residentMB: 80,
            workingDirectory: "\(worktreeRoot)/src"
        )
    }

    @Test("sample captures recognized agent executable names")
    func sampleCapturesRecognizedAgentExecutableName() {
        let worktreeID = UUID()
        let leafID = UUID()

        let monitor = ProcessResourceMonitor.fake(
            processes: [
                .app(pid: 100, residentMB: 32, executableName: "Ghosthub"),
                .init(
                    pid: 200, residentMB: 64,
                    executableName: "codex --yolo"
                ),
            ]
        )

        let snapshot = monitor.sample(
            rootPID: 200, worktreeID: worktreeID, leafID: leafID
        )

        let process = snapshot?.processes.first { $0.leafID == leafID }
        #expect(process?.executableName == "codex --yolo")
        #expect(process?.recognizedAgent == .codex)
    }

    @Test("resource summary ignores the monitor root working directory")
    func resourceSummaryIgnoresMonitorRootWorkingDirectory() {
        let hostID = UUID()
        let projectID = UUID()
        let worktreeID = UUID()
        let worktreeRoot = "/tmp/worktrees/ghosthub"

        let snapshot = WorkspaceSnapshot.singleWorktreeFixture(
            hostID: hostID,
            projectID: projectID,
            worktreeID: worktreeID,
            worktreePath: worktreeRoot,
            worktreeBranch: "feature/resource"
        )

        let summary = WorkspaceResourceModel.summary(
            snapshot: snapshot,
            selectedHostID: hostID,
            aggregate: WorkspaceResourceSample(
                cpuPercent: 3.0,
                residentMB: 260,
                processCount: 4
            ),
            processes: [
                .fixture(cpuPercent: 0.5, residentMB: 50),
                .fixture(cpuPercent: 0.7, residentMB: 60),
                .fixture(
                    worktreeID: worktreeID,
                    workingDirectory: worktreeRoot,
                    cpuPercent: 0.8,
                    residentMB: 70
                ),
                .fixture(
                    worktreeID: worktreeID,
                    workingDirectory: "\(worktreeRoot)/src",
                    cpuPercent: 1.0,
                    residentMB: 80
                ),
            ],
            lastUpdatedAt: Date(),
            refreshIntervalSeconds: 5
        )

        #expect(
            summary.worktreeSamples[worktreeID]
                == WorkspaceResourceSample(
                    cpuPercent: 1.8,
                    residentMB: 150,
                    processCount: 2
                )
        )
    }

    @Test("sample attributes the process tree to worktree and leaf roots")
    func sampleAttributesProcessTreeToWorktreeAndLeafRoots() {
        let monitor = ProcessResourceMonitor()
        let worktreeID = UUID()
        let leafID = UUID()

        let snapshot = monitor.sample(
            rootPID: getpid(), worktreeID: worktreeID,
            leafID: leafID
        )

        #expect(snapshot != nil)
        #expect(
            snapshot?.processes.contains {
                $0.worktreeID == worktreeID && $0.leafID == leafID
            } == true
        )
    }

    @Test("sample includes explicit roots outside the app process tree")
    func sampleIncludesExplicitRootsOutsideAppProcessTree() {
        let worktreeID = UUID()
        let leafID = UUID()

        let monitor = ProcessResourceMonitor.fake(
            processes: [
                .app(pid: 100, residentMB: 50),
                .init(
                    pid: 200, residentMB: 120, children: [201],
                    workingDirectory: "/tmp"
                ),
                .init(
                    pid: 201, residentMB: 80,
                    workingDirectory: "/tmp"
                ),
            ]
        )

        let snapshot = monitor.sample(
            rootPID: 200, worktreeID: worktreeID, leafID: leafID
        )

        #expect(snapshot?.processes.count == 3)
        assertSnapshotContains(
            snapshot,
            worktreeID: worktreeID,
            leafID: leafID,
            residentMB: 120
        )
        assertSnapshotContains(
            snapshot,
            worktreeID: worktreeID,
            leafID: leafID,
            residentMB: 80
        )
    }

    @Test("direct sampling preserves CPU baselines across calls")
    func directSampleOverloadPreservesCpuBaselineAcrossCalls() {
        let appPID: pid_t = 100
        var cpuValue: UInt64 = 1_000_000_000
        let monitor = ProcessResourceMonitor(
            rootPIDProvider: { appPID },
            childProcessProvider: { _ in [] },
            processUsageProvider: { pid in
                guard pid == appPID else { return nil }
                defer { cpuValue += 1_000_000_000 }
                return (cpuValue, 50)
            }
        )

        _ = monitor.sample(
            roots: [], now: Date(timeIntervalSince1970: 1)
        )
        let second = monitor.sample(
            roots: [], now: Date(timeIntervalSince1970: 2)
        )

        #expect(second?.aggregate.processCount == 1)
        #expect((second?.aggregate.cpuPercent ?? 0) > 0)
    }

    @Test("sample falls back to the snapshot for login-like roots")
    func sampleFallsBackToSnapshotForLoginLikeRoots() {
        let appPID: pid_t = 91_100
        let loginPID: pid_t = 91_200
        let shellPID: pid_t = 91_201
        let worktreeID = UUID()
        let leafID = UUID()

        let monitor = ProcessResourceMonitor(
            rootPIDProvider: { appPID },
            childProcessProvider: { _ in nil },
            processUsageProvider: { pid in
                pid == appPID ? (1_000_000_000, 50) : nil
            },
            processWorkingDirectoryProvider: { pid in
                pid == shellPID ? "/tmp/worktree" : nil
            },
            processSnapshotProvider: {
                [
                    loginPID: ProcessSnapshotEntry(
                        parentPID: 999,
                        cpuPercent: 0.4, residentMB: 4
                    ),
                    shellPID: ProcessSnapshotEntry(
                        parentPID: loginPID,
                        cpuPercent: 1.8, residentMB: 96
                    ),
                ]
            }
        )

        let snapshot = monitor.sample(
            rootPID: loginPID, worktreeID: worktreeID,
            leafID: leafID
        )

        #expect(snapshot?.processes.count == 3)
        assertSnapshotContains(
            snapshot,
            worktreeID: worktreeID,
            leafID: leafID,
            residentMB: 96
        )
    }

    @Test("sample prefers pane attribution when session and pane roots overlap")
    func samplePrefersPaneAttributionWhenSessionAndPaneRootsOverlap() {
        let worktreeID = UUID()
        let paneLeafID = UUID()

        let monitor = ProcessResourceMonitor.fake(
            processes: [
                .app(pid: 100, residentMB: 20),
                .init(pid: 200, residentMB: 40, children: [201]),
                .init(pid: 201, residentMB: 80, children: [202]),
                .init(pid: 202, residentMB: 60),
            ]
        )

        let snapshot = monitor.sample(
            roots: [
                // Deliberately provide the more-specific pane root
                // first to prove attribution does not depend on
                // caller order.
                .fixture(
                    pid: 201, worktreeID: worktreeID,
                    leafID: paneLeafID
                ),
                .fixture(pid: 200, worktreeID: worktreeID),
            ],
            now: Date()
        )

        #expect(snapshot?.processes.count == 4)
        assertSnapshotContains(
            snapshot, residentMB: 40,
            worktreeID: worktreeID, leafID: nil
        )
        assertSnapshotContains(
            snapshot, residentMB: 80,
            worktreeID: worktreeID, leafID: paneLeafID
        )
        assertSnapshotContains(
            snapshot, residentMB: 60,
            worktreeID: worktreeID, leafID: paneLeafID
        )
    }

    @Test("sample does not load the process snapshot when direct enumeration succeeds")
    func sampleDoesNotLoadProcessSnapshotWhenDirectEnumerationAndUsageSucceed() {
        var snapshotLoadCount = 0

        let monitor = ProcessResourceMonitor.fake(
            processes: [
                .app(pid: 100, residentMB: 20, children: [101]),
                .init(pid: 101, residentMB: 40),
            ],
            processSnapshotProvider: {
                snapshotLoadCount += 1
                return [
                    101: ProcessSnapshotEntry(
                        parentPID: 100,
                        cpuPercent: 0.3, residentMB: 4
                    ),
                ]
            }
        )

        let snapshot = monitor.sample(now: Date())

        #expect(snapshot?.processes.count == 2)
        #expect(snapshotLoadCount == 0)
    }

    @Test("sample loads the process snapshot lazily when direct enumeration fails")
    func sampleLoadsProcessSnapshotLazilyWhenDirectEnumerationFails() {
        let appPID: pid_t = 92_100
        let shellPID: pid_t = 92_200
        var snapshotLoadCount = 0

        let monitor = ProcessResourceMonitor(
            rootPIDProvider: { appPID },
            childProcessProvider: { _ in nil },
            processUsageProvider: { pid in
                pid == appPID ? (1_000_000_000, 20) : nil
            },
            processSnapshotProvider: {
                snapshotLoadCount += 1
                return [
                    shellPID: ProcessSnapshotEntry(
                        parentPID: appPID,
                        cpuPercent: 1.5, residentMB: 64
                    ),
                ]
            }
        )

        let snapshot = monitor.sample(now: Date())

        #expect(snapshotLoadCount == 1)
        assertSnapshotContains(snapshot, residentMB: 64)
    }

    @Test("sample merges snapshot-only siblings when direct enumeration is partial")
    func sampleMergesSnapshotOnlySiblingsWhenDirectEnumerationIsPartial() {
        let worktreeID = UUID()
        let leafID = UUID()

        let monitor = ProcessResourceMonitor.fake(
            processes: [
                .app(pid: 100, residentMB: 20),
                .init(
                    pid: 200, residentMB: 40, children: [201]
                ),
                .init(pid: 201, residentMB: 60),
            ],
            processSnapshotProvider: {
                [
                    200: ProcessSnapshotEntry(
                        parentPID: 999,
                        cpuPercent: 0.4, residentMB: 8
                    ),
                    201: ProcessSnapshotEntry(
                        parentPID: 200,
                        cpuPercent: 1.0, residentMB: 60
                    ),
                    202: ProcessSnapshotEntry(
                        parentPID: 200,
                        cpuPercent: 2.0, residentMB: 90
                    ),
                ]
            }
        )

        let snapshot = monitor.sample(
            roots: [.fixture(
                pid: 200, worktreeID: worktreeID, leafID: leafID
            )],
            now: Date()
        ).snapshot

        assertSnapshotContains(
            snapshot,
            worktreeID: worktreeID,
            leafID: leafID,
            residentMB: 60
        )
        assertSnapshotContains(
            snapshot,
            worktreeID: worktreeID,
            leafID: leafID,
            residentMB: 90
        )
    }
}

// MARK: - Assertion Helpers

extension ProcessResourceMonitorTests {
    private func assertSnapshotContains(
        _ snapshot: ProcessTreeSnapshot?,
        worktreeID: UUID? = nil,
        leafID: UUID? = nil,
        residentMB: Int? = nil,
        workingDirectory: String?? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let match = snapshot?.processes.contains { proc in
            if let worktreeID, proc.worktreeID != worktreeID {
                return false
            }
            if let leafID, proc.leafID != leafID {
                return false
            }
            if let residentMB,
               proc.sample.residentMB != residentMB {
                return false
            }
            if let workingDirectory,
               proc.workingDirectory != workingDirectory {
                return false
            }
            return true
        }
        if match != true {
            Issue.record(
                Comment(rawValue: """
                Expected snapshot to contain a process matching \(snapshotMatchDescription(
                    worktreeID: worktreeID,
                    leafID: leafID,
                    residentMB: residentMB,
                    workingDirectory: workingDirectory
                )).
                """),
                sourceLocation: sourceLocation
            )
        }
        #expect(match == true, sourceLocation: sourceLocation)
    }

    /// Overload that accepts `leafID: UUID?` for explicit nil matching.
    private func assertSnapshotContains(
        _ snapshot: ProcessTreeSnapshot?,
        residentMB: Int,
        worktreeID: UUID,
        leafID: UUID?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let match = snapshot?.processes.contains { proc in
            proc.worktreeID == worktreeID
                && proc.leafID == leafID
                && proc.sample.residentMB == residentMB
        }
        if match != true {
            Issue.record(
                Comment(rawValue: """
                Expected snapshot to contain a process matching \(snapshotMatchDescription(
                    worktreeID: worktreeID,
                    leafID: leafID,
                    residentMB: residentMB,
                    workingDirectory: nil
                )).
                """),
                sourceLocation: sourceLocation
            )
        }
        #expect(match == true, sourceLocation: sourceLocation)
    }

    private func snapshotMatchDescription(
        worktreeID: UUID?,
        leafID: UUID?,
        residentMB: Int?,
        workingDirectory: String??
    ) -> String {
        var parts: [String] = []
        if let worktreeID {
            parts.append("worktreeID=\(worktreeID.uuidString)")
        }
        if let leafID {
            parts.append("leafID=\(leafID.uuidString)")
        }
        if let residentMB {
            parts.append("residentMB=\(residentMB)")
        }
        if let workingDirectory {
            switch workingDirectory {
            case let .some(path):
                parts.append("workingDirectory=\(path)")
            case .none:
                parts.append("workingDirectory=nil")
            }
        }
        return parts.isEmpty ? "the requested predicate" : parts.joined(separator: ", ")
    }
}

// MARK: - Sampling Helpers

extension ProcessResourceMonitor {
    /// Convenience for tests that sample a single root process.
    fileprivate func sample(
        rootPID: pid_t,
        worktreeID: UUID,
        leafID: UUID? = nil
    ) -> ProcessTreeSnapshot? {
        sample(
            roots: [.fixture(
                pid: rootPID, worktreeID: worktreeID,
                leafID: leafID
            )],
            now: Date()
        )
    }
}

// MARK: - Mock Process Tree Builder

private struct MockProcess {
    var pid: pid_t
    var cpuTimeNanos: UInt64
    var residentMB: Int
    var children: [pid_t]
    var workingDirectory: String?
    var executableName: String?

    init(
        pid: pid_t,
        cpuTimeNanos: UInt64? = nil,
        residentMB: Int = 32,
        children: [pid_t] = [],
        workingDirectory: String? = nil,
        executableName: String? = nil
    ) {
        self.pid = pid
        self.cpuTimeNanos = cpuTimeNanos
            ?? UInt64(pid) * 1_000_000_000
        self.residentMB = residentMB
        self.children = children
        self.workingDirectory = workingDirectory
        self.executableName = executableName
    }

    static func app(
        pid: pid_t = 100,
        residentMB: Int = 32,
        children: [pid_t] = [],
        executableName: String? = nil
    ) -> MockProcess {
        MockProcess(
            pid: pid, residentMB: residentMB,
            children: children, executableName: executableName
        )
    }
}

extension ProcessResourceMonitor {
    fileprivate static func fake(
        processes: [MockProcess],
        processSnapshotProvider: @escaping ()
            -> [pid_t: ProcessSnapshotEntry]? = { nil }
    ) -> ProcessResourceMonitor {
        let appProcess = processes.first!
        let byPID = Dictionary(
            uniqueKeysWithValues: processes.map { ($0.pid, $0) }
        )

        return ProcessResourceMonitor(
            rootPIDProvider: { appProcess.pid },
            childProcessProvider: { pid in
                byPID[pid]?.children ?? []
            },
            processUsageProvider: { pid in
                guard let proc = byPID[pid] else { return nil }
                return (proc.cpuTimeNanos, proc.residentMB)
            },
            processWorkingDirectoryProvider: { pid in
                byPID[pid]?.workingDirectory
            },
            processExecutableNameProvider: { pid in
                byPID[pid]?.executableName
            },
            processSnapshotProvider: processSnapshotProvider
        )
    }
}

// MARK: - Model Fixtures

extension WorkspaceProcessRoot {
    fileprivate static func fixture(
        pid: pid_t,
        worktreeID: UUID? = UUID(),
        leafID: UUID? = nil
    ) -> WorkspaceProcessRoot {
        WorkspaceProcessRoot(
            pid: pid, worktreeID: worktreeID, leafID: leafID
        )
    }
}

extension WorkspaceSnapshot {
    fileprivate static func singleWorktreeFixture(
        hostID: UUID = UUID(),
        projectID: UUID = UUID(),
        worktreeID: UUID = UUID(),
        hostName: String = "This Mac",
        projectName: String = "ghosthub",
        worktreePath: String = "/tmp/worktrees/ghosthub",
        worktreeBranch: String = "main"
    ) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            hosts: [
                HostSummary(
                    id: hostID, name: hostName,
                    kind: .selfHost, platform: .macOS
                ),
            ],
            projects: [
                ProjectSummary(
                    id: projectID, hostID: hostID,
                    name: projectName, rootPath: worktreePath
                ),
            ],
            worktrees: [
                WorktreeSummary(
                    id: worktreeID, hostID: hostID,
                    projectID: projectID, name: "feature",
                    path: worktreePath, branch: worktreeBranch
                ),
            ]
        )
    }
}

extension WorkspaceProcessResource {
    fileprivate static func fixture(
        worktreeID: UUID? = nil,
        leafID: UUID? = nil,
        workingDirectory: String? = nil,
        cpuPercent: Double = 0.0,
        residentMB: Int = 0,
        processCount: Int = 1
    ) -> Self {
        WorkspaceProcessResource(
            worktreeID: worktreeID,
            leafID: leafID,
            workingDirectory: workingDirectory,
            sample: WorkspaceResourceSample(
                cpuPercent: cpuPercent,
                residentMB: residentMB,
                processCount: processCount
            )
        )
    }
}
