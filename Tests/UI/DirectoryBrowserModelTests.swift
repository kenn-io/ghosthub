import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

@Suite("Directory browser")
struct DirectoryBrowserModelTests {
    @Test(
        "folder reads occur only for an expanded uncached full listing",
        arguments: [
            (false, false, false), (false, false, true),
            (false, true, false), (false, true, true),
            (true, false, false), (true, false, true),
            (true, true, false), (true, true, true),
        ]
    )
    func loadingPolicy(expanded: Bool, showUnregistered: Bool, cached: Bool) {
        #expect(DirectoryBrowserModel.shouldLoad(
            expanded: expanded, showUnregisteredFolders: showUnregistered, hasListing: cached
        ) == (expanded && showUnregistered && !cached))
    }

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

    @Test("registered projects remain reachable through every ancestor before browsing")
    func coldRegisteredTree() throws {
        let registered = project(path: "/hub/team/widget/main")
        #expect(DirectoryBrowserModel.containsRegistrations(
            beneath: "/hub/team/widget", directories: [], projects: [registered]
        ))
        #expect(!DirectoryBrowserModel.containsRegistrations(
            beneath: "/hub/team/widget-other", directories: [], projects: [registered]
        ))
        for (parent, expected) in [
            ("/hub", "/hub/team"),
            ("/hub/team", "/hub/team/widget"),
            ("/hub/team/widget", "/hub/team/widget/main"),
        ] {
            let children = DirectoryBrowserModel.children(
                of: parent, entries: [], directories: [], projects: [registered],
                showUnregisteredFolders: false
            )
            #expect(children.map(\.path) == [expected])
            if expected == registered.project.rootPath {
                let child = try #require(children.first)
                #expect(DirectoryBrowserModel.project(for: child, in: [registered])?.id
                    == registered.id)
            }
        }
    }

    @Test("show then hide retains a recognized registered container and removes unrelated folders")
    func registeredContainerAfterBrowse() throws {
        let registered = project(path: "/hub/widget/main")
        let entries = [
            DirectoryEntry(name: "widget", path: "/hub/widget", projectPath: "/hub/widget/main"),
            DirectoryEntry(name: "unused", path: "/hub/unused"),
        ]
        for showUnregistered in [false, true, false] {
            let children = DirectoryBrowserModel.children(
                of: "/hub", entries: entries, directories: [], projects: [registered],
                showUnregisteredFolders: showUnregistered
            )
            #expect(children.map(\.name) == (showUnregistered ? ["unused", "widget"] : ["widget"]))
            let container = try #require(children.first { $0.name == "widget" })
            #expect(DirectoryBrowserModel.project(for: container, in: [registered])?.id
                == registered.id)
        }
    }

    @Test("large listings retain exactly the registered projects")
    func largeListing() {
        let entries = (0 ..< 1000).map {
            DirectoryEntry(name: "folder-\($0)", path: "/hub/folder-\($0)")
        }
        let projects = (0 ..< 500).map { project(path: "/hub/folder-\($0)") }
        let duration = ContinuousClock().measure {
            for _ in 0 ..< 10 {
                let children = DirectoryBrowserModel.children(
                    of: "/hub", entries: entries, directories: [], projects: projects,
                    showUnregisteredFolders: false
                )
                #expect(Set(children.map(\.path)) == Set(projects.map(\.project.rootPath)))
            }
        }
        print("Directory projection: 10 x 1,000 folders / 500 projects: \(duration)")
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
