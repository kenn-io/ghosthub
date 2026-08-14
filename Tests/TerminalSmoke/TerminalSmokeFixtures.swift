import AppKit
import Foundation
import GhosthubTestSupport
import GhosthubWorkspace
@testable import GhosthubApp
@testable import GhosthubTerminal
@testable import GhosthubTerminalSupport
import XCTest

@MainActor
final class InMemoryTerminalPasteboard: TerminalPasteboard {
    private var contents: [NSPasteboard.PasteboardType: String] = [:]

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        contents[dataType]
    }

    @discardableResult
    func clearContents() -> Int {
        contents.removeAll()
        return 1
    }

    @discardableResult
    func declareTypes(
        _ newTypes: [NSPasteboard.PasteboardType],
        owner newOwner: Any?
    ) -> Int {
        contents.removeAll()
        return newTypes.count
    }

    @discardableResult
    func setString(
        _ string: String,
        forType dataType: NSPasteboard.PasteboardType
    ) -> Bool {
        contents[dataType] = string
        return true
    }
}

// MARK: - Skip Guard

func skipUnlessLibghosttyReady() throws {
    guard LibghosttyBootstrap.status().isReady else {
        throw XCTSkip("libghostty not bootstrapped")
    }
}

extension XCTestCase {
    func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString, isDirectory: true
            )
        try! FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

// MARK: - Isolated Pipeline

func makeIsolatedPipeline() -> (LibghosttyConfigPipeline, URL) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(
        at: tempRoot,
        withIntermediateDirectories: true
    )
    let configDirectory = tempRoot
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("ghosthub", isDirectory: true)
    return (
        LibghosttyConfigPipeline(
            paths: .init(configDirectory: configDirectory)
        ),
        tempRoot
    )
}

func makeIsolatedSurfacePipeline() -> (LibghosttyConfigPipeline, URL) {
    let (pipeline, tempRoot) = makeIsolatedPipeline()
    try! FileManager.default.createDirectory(
        at: pipeline.paths.configDirectory,
        withIntermediateDirectories: true
    )
    try! "window-vsync = false\n".write(
        to: pipeline.paths.terminalAppearanceConfigFile,
        atomically: true,
        encoding: .utf8
    )
    return (pipeline, tempRoot)
}

func withIsolatedPipeline<T>(
    _ block: (LibghosttyConfigPipeline, URL) throws -> T
) throws -> T {
    try withTemporaryDirectory { tempRoot in
        let configDirectory = tempRoot
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghosthub", isDirectory: true)
        let pipeline = LibghosttyConfigPipeline(
            paths: .init(configDirectory: configDirectory)
        )
        return try block(pipeline, tempRoot)
    }
}

// MARK: - Model Fixtures

extension WorkspaceSnapshot {
    static func singleWorktreeFixture(
        hostID: UUID = UUID(),
        projectID: UUID = UUID(),
        worktreeID: UUID = UUID(),
        hostName: String = "This Mac",
        projectName: String = "ghosthub",
        projectRootPath: String? = nil,
        worktreeName: String = "root",
        worktreePath: String = "/tmp/ghosthub",
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
                    name: projectName,
                    rootPath: projectRootPath ?? worktreePath
                ),
            ],
            worktrees: [
                WorktreeSummary(
                    id: worktreeID, hostID: hostID,
                    projectID: projectID, name: worktreeName,
                    path: worktreePath, branch: worktreeBranch
                ),
            ]
        )
    }
}

// MARK: - Workspace Test Context

struct WorkspaceTestContext {
    let hostID = UUID()
    let projectID = UUID()
    let worktreeID = UUID()
    let leafID = UUID()

    var snapshot: WorkspaceSnapshot {
        WorkspaceSnapshot.singleWorktreeFixture(
            hostID: hostID,
            projectID: projectID,
            worktreeID: worktreeID
        )
    }

    func surfaceKey(
        target: TerminalSurfaceTarget = .worktreeShell,
        leafID: UUID? = nil
    ) -> SurfaceKey {
        SurfaceKey.fixture(
            worktreeID: worktreeID,
            hostID: hostID,
            target: target,
            leafID: leafID
        )
    }
}

extension SurfaceKey {
    static func fixture(
        worktreeID: UUID? = UUID(),
        hostID: UUID = UUID(),
        target: TerminalSurfaceTarget = .worktreeShell,
        leafID: UUID? = nil
    ) -> SurfaceKey {
        SurfaceKey(
            worktreeID: worktreeID,
            hostID: hostID,
            target: target,
            leafID: leafID
        )
    }
}
