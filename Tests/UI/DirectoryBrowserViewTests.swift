import AppKit
import Foundation
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubUI

@Suite(.serialized)
@MainActor
struct DirectoryBrowserViewTests {
    @Test(
        "nested registrations stay reachable beneath a registered project",
        arguments: [false, true]
    )
    func nestedRegistrations(dark: Bool) throws {
        let app = NSApplication.shared
        let enhanced = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(enhanced, forKey: "accessibilityEnhancedUserInterface") }
        var host = HostSummary.fixture()
        host.name = "This Mac"
        let parent = ProjectSummary(
            id: UUID(), hostID: host.id, name: "Atlas", rootPath: "/code/Studio/Atlas"
        )
        let child = ProjectSummary(
            id: UUID(), hostID: host.id, name: "Docs", rootPath: "/code/Studio/Atlas/Docs"
        )
        let directories = [("Studio", "/code/Studio"), ("Notes", "/code/Studio/Atlas/Notes")]
            .map { name, path in
                DirectoryWorkspaceSummary(
                    id: UUID(), hostID: host.id, name: name, path: path,
                    tmuxSessionName: name, sessionLive: false
                )
            }
        let worktrees = [parent, child].map { project in
            WorktreeSummary(
                id: UUID(), hostID: host.id, projectID: project.id,
                name: "main", path: project.rootPath, branch: "main", isPrimary: true
            )
        }
        var snapshot = WorkspaceSnapshot.fixture(
            hosts: [host], projects: [parent, child], worktrees: worktrees
        )
        snapshot.directoryWorkspaces = directories
        var reads: [String] = []
        var opens = 0
        let view = hostView(
            WorkspaceSidebarView(
                snapshot: snapshot, sectionCache: WorkspaceSidebarSectionCache(),
                selection: .constant(WorkspaceSelection(selectedHostID: host.id)),
                visibility: WorktreeVisibility(),
                browseDirectory: { _, path in
                    reads.append(path)
                    let entries = path == "/code/Studio"
                        ? [DirectoryEntry(
                            name: "Atlas",
                            path: parent.rootPath,
                            projectPath: parent.rootPath
                        )]
                        : []
                    return .success(DirectoryListing(
                        path: path,
                        entries: entries,
                        truncated: false
                    ))
                },
                onOpen: { _ in opens += 1 }
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(dark ? .dark : .light),
            size: CGSize(width: 400, height: 560)
        )
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Ghosthub"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.close() }
        func settle() {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            view.layoutSubtreeIfNeeded()
        }
        func press(_ value: String, attribute: String = "accessibilityLabel") throws {
            let element = try #require(find(value, attribute: attribute, in: view))
            _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
            settle()
        }
        settle()
        try press(
            "sidebar-section-disclosure-projects:\(host.id.uuidString)",
            attribute: "accessibilityIdentifier"
        )
        try press("Expand Studio")
        try press("Expand Atlas")
        #expect(reads == ["/code/Studio"], "worktree expansion must not scan folders")
        try press("Expand folders in Atlas")
        try press("Expand Docs")
        #expect(find("Expand Notes", in: view) != nil)
        #expect(reads == ["/code/Studio", "/code/Studio/Atlas"])
        #expect(opens == 0)
        if let directory = ProcessInfo.processInfo
            .environment["GHOSTHUB_DIRECTORY_SCREENSHOT_DIR"] {
            let frame = try #require(window.contentView?.superview)
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: directory)
                .appendingPathComponent("guide-directory-browser\(dark ? "" : "-light").png")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try png.write(to: url, options: .atomic)
        }
        // Recognizing a project must not remove discovery of new descendants.
        try press("Expand folders in Docs")
        #expect(reads == ["/code/Studio", "/code/Studio/Atlas", "/code/Studio/Atlas/Docs"])
        try press("Collapse Studio")
        try press("Expand Studio")
        #expect(reads.filter { $0 == "/code/Studio" }.count == 1)
    }

    private func find(
        _ value: String, attribute: String = "accessibilityLabel", in element: NSObject
    ) -> NSObject? {
        if element.responds(to: NSSelectorFromString(attribute)),
           element.value(forKey: attribute) as? String == value {
            return element
        }
        guard element.responds(to: NSSelectorFromString("accessibilityChildren")),
              let children = element.value(forKey: "accessibilityChildren") as? [NSObject]
        else { return nil }
        return children.lazy.compactMap { find(value, attribute: attribute, in: $0) }.first
    }
}
