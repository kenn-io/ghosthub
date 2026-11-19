import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

@Suite("Directory browser")
struct DirectoryBrowserModelTests {
    private func project(path: String) -> WorkspaceSidebarProject {
        WorkspaceSidebarProject(
            project: ProjectSummary(id: UUID(), hostID: UUID(), name: "widget", rootPath: path),
            worktrees: [], worktreeRows: []
        )
    }

    @Test("bare containers and linked worktrees resolve to one registered project")
    func canonicalProject() {
        let project = project(path: "/hub/widget/main")
        let container = DirectoryEntry(
            name: "widget",
            path: "/hub/widget",
            projectPath: "/hub/widget/main"
        )
        #expect(DirectoryBrowserModel.project(for: container, in: [project])?.id == project.id)
        let entries = ["main", "topic"].map {
            DirectoryEntry(
                name: $0,
                path: "/hub/widget/\($0)",
                projectPath: project.project.rootPath
            )
        }
        let children = DirectoryBrowserModel.children(
            of: "/hub/widget", entries: entries, directories: [], projects: [project]
        )
        #expect(children.count == 1)
    }

    @Test("unregistered folders remain visible and known missing projects remain reachable")
    func mixedInventory() {
        let entries = [DirectoryEntry(name: "notes", path: "/hub/notes")]
        let children = DirectoryBrowserModel.children(
            of: "/hub", entries: entries, directories: [],
            projects: [project(path: "/hub/missing/main"), project(path: "/hub-other/main")]
        )
        #expect(children.map(\.name) == ["missing", "notes"])
        #expect(children.allSatisfy { $0.projectPath == nil })
    }

    @Test("hiding unregistered folders retains registrations and their ancestor paths")
    func hideUnregisteredFolders() {
        let entries = [
            DirectoryEntry(name: "unused", path: "/hub/unused"),
            DirectoryEntry(name: "checkout", path: "/hub/checkout", projectPath: "/elsewhere/main"),
            DirectoryEntry(name: "unloaded", path: "/hub/unloaded", projectPath: "/hub/unloaded"),
        ]
        let directories = [DirectoryWorkspaceSummary(
            id: UUID(), hostID: UUID(), name: "notes", path: "/hub/notes",
            tmuxSessionName: "notes", sessionLive: false
        )]
        let projects = [project(path: "/elsewhere/main"), project(path: "/hub/team/widget/main")]
        let hidden = DirectoryBrowserModel.children(
            of: "/hub", entries: entries, directories: directories, projects: projects,
            showUnregisteredFolders: false
        )
        #expect(hidden.map(\.name) == ["checkout", "notes", "team"])
        let shown = DirectoryBrowserModel.children(
            of: "/hub", entries: entries, directories: directories, projects: projects,
            showUnregisteredFolders: true
        )
        #expect(shown.map(\.name) == ["checkout", "notes", "team", "unloaded", "unused"])
    }

    @Test("group roots compare host and path components")
    func roots() {
        let hostID = UUID()
        func directory(_ path: String, host: UUID) -> DirectoryWorkspaceSummary {
            DirectoryWorkspaceSummary(
                id: UUID(), hostID: host, name: path, path: path,
                tmuxSessionName: path, sessionLive: false
            )
        }
        let parent = directory("/hub", host: hostID)
        let nested = directory("/hub/notes", host: hostID)
        let sibling = directory("/hub-other", host: hostID)
        let remote = directory("/hub/notes", host: UUID())
        #expect(DirectoryBrowserModel.roots([parent, nested, sibling, remote]).map(\.id)
            == [parent.id, sibling.id, remote.id])
        #expect(DirectoryPaths.contains("/hub/./", "/hub/a/../widget/main"))
        #expect(!DirectoryPaths.contains("/hub", "/hub"))
        #expect(!DirectoryPaths.contains("/hub", "/hub-other"))
    }
}
