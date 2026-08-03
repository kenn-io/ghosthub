import Foundation
import GhosthubPersistence
import GhosthubTerminalSupport
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp
@testable import GhosthubTerminal

@Suite("Workspace terminal configuration", .serialized)
@MainActor
struct WorkspaceTerminalConfigTests {
    @Test("only the focused window selects the app-wide project config")
    func focusedWindowSelectsProjectConfig() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let pipeline = LibghosttyConfigPipeline(
            paths: LibghosttyConfigPaths(
                configDirectory: tempRoot.appendingPathComponent(
                    "config",
                    isDirectory: true
                )
            )
        )
        try FileManager.default.createDirectory(
            at: pipeline.paths.configDirectory,
            withIntermediateDirectories: true
        )
        try "font-size = 13\n".write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )
        let runtime = LibghosttyRuntime(pipeline: pipeline)
        let hostID = UUID()
        let firstProject = ProjectSummary.fixture(
            hostID: hostID,
            rootPath: tempRoot.appendingPathComponent("first").path
        )
        let secondProject = ProjectSummary.fixture(
            hostID: hostID,
            rootPath: tempRoot.appendingPathComponent("second").path
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(id: hostID)],
            projects: [firstProject, secondProject],
            worktrees: []
        )
        let firstModel = try makeModel(
            database: .inMemory(),
            localHostID: hostID,
            snapshot: snapshot,
            terminalRuntime: runtime
        )
        let secondModel = try makeModel(
            database: .inMemory(),
            localHostID: hostID,
            snapshot: snapshot,
            terminalRuntime: runtime
        )

        firstModel.selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedProjectID: firstProject.id
        )
        secondModel.selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedProjectID: secondProject.id
        )
        firstModel.isFocusedWindow = true
        let firstConfig = pipeline.paths.projectConfigFile(
            for: URL(fileURLWithPath: firstProject.rootPath)
        )
        #expect(
            runtime.configPlan?.watchedConfigFiles.contains(firstConfig)
                == true
        )

        #expect(
            runtime.configPlan?.watchedConfigFiles.contains(firstConfig)
                == true
        )

        firstModel.isFocusedWindow = false
        secondModel.isFocusedWindow = true
        let secondConfig = pipeline.paths.projectConfigFile(
            for: URL(fileURLWithPath: secondProject.rootPath)
        )
        #expect(
            runtime.configPlan?.watchedConfigFiles.contains(secondConfig)
                == true
        )
    }
}
