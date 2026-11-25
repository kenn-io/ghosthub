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
        arguments: [false, true], [false, true]
    )
    func nestedRegistrations(dark: Bool, delayedListing: Bool) async throws {
        try await checkNestedRegistrations(
            dark: dark,
            delayedListing: delayedListing,
            registeredAncestor: true
        )
    }

    @Test("root projects expose nested registrations and on-demand folder actions")
    func rootProjectRegistrations() async throws {
        try await checkNestedRegistrations(
            dark: false,
            delayedListing: false,
            registeredAncestor: false
        )
    }

    private func checkNestedRegistrations(
        dark: Bool,
        delayedListing: Bool,
        registeredAncestor: Bool
    ) async throws {
        let app = NSApplication.shared
        let enhanced = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(enhanced, forKey: "accessibilityEnhancedUserInterface") }
        var host = HostSummary.fixture()
        host.name = "This Mac"
        let parent = ProjectSummary(
            id: UUID(), hostID: host.id, name: "Atlas",
            rootPath: "/code/Studio/Atlas"
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
        snapshot
            .directoryWorkspaces = registeredAncestor ? directories : Array(directories.dropFirst())
        var reads: [String] = []
        var finishListing: CheckedContinuation<Void, Never>?
        var opens = 0
        let view = hostView(
            WorkspaceSidebarView(
                snapshot: snapshot, sectionCache: WorkspaceSidebarSectionCache(),
                selection: .constant(WorkspaceSelection(selectedHostID: host.id)),
                visibility: WorktreeVisibility(),
                browseDirectory: { _, path in
                    reads.append(path)
                    if delayedListing && path == "/code/Studio" {
                        await withCheckedContinuation { finishListing = $0 }
                    }
                    let entries = path == "/code/Studio"
                        ? [DirectoryEntry(
                            name: "Atlas",
                            path: "/code/Studio/Atlas",
                            projectPath: parent.rootPath
                        )]
                        : [DirectoryEntry(name: "Unregistered", path: path + "/Unregistered")]
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
        func settle() async throws {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            view.layoutSubtreeIfNeeded()
        }
        func press(_ value: String, attribute: String = "accessibilityLabel") async throws {
            guard let element = find(value, attribute: attribute, in: view) else {
                Issue.record("Missing accessibility element: \(value)")
                return
            }
            _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
            try await settle()
        }
        func clickDisclosurePadding(_ label: String) async throws {
            guard let element = find(label, in: view) else {
                Issue.record("Missing disclosure: \(label)")
                return
            }
            let frameValue = element.value(forKey: "accessibilityFrame") as? NSValue
            let frame = try #require(frameValue).rectValue
            // Use the intended 18×28 button area, not the glyph's accessible bounds.
            let point = window.convertPoint(fromScreen: NSPoint(
                x: frame.midX - 8,
                y: frame.midY - 13
            ))
            syntheticClick(at: view.convert(point, from: nil), in: view, window: window)
            try await settle()
        }
        func folderAction(_ name: String, project: String) async throws {
            let row = try #require(find("Folder actions for \(project)", in: view))
            let actions = try #require(
                row.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction]
            )
            let action = try #require(actions.first { $0.name == name })
            if let handler = action.handler {
                #expect(handler())
            } else {
                let target = try #require(action.target as? NSObject)
                let selector = try #require(action.selector)
                typealias Action = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
                let invoke = unsafeBitCast(target.method(for: selector), to: Action.self)
                #expect(invoke(target, selector, action))
            }
            try await settle()
        }
        try await settle()
        try await press(
            "sidebar-section-disclosure-projects:\(host.id.uuidString)",
            attribute: "accessibilityIdentifier"
        )
        if registeredAncestor {
            try await clickDisclosurePadding("Expand Studio")
            #expect(find("Collapse Studio", in: view) != nil)
        } else {
            #expect(find("Expand Docs", in: view) == nil)
            #expect(find("Expand Notes", in: view) == nil)
        }
        let initialReads = registeredAncestor ? ["/code/Studio"] : []
        if delayedListing {
            #expect(find("Loading projects…", in: view) != nil)
            #expect(
                find("Expand Atlas", in: view) != nil,
                "known projects must appear before the folder lookup completes"
            )
            finishListing?.resume()
            try await settle()
            let stillLoading = find("Loading projects…", in: view) != nil
            #expect(
                !stillLoading,
                "the first lookup must publish its result"
            )
        }
        try await press("Expand Atlas")
        #expect(reads == initialReads, "worktree expansion must not scan folders")
        #expect(find("Expand folders in Atlas", in: view) == nil)
        #expect(find("Expand Notes", in: view) != nil)
        try await press("Expand Docs")
        #expect(find("Expand Notes", in: view) != nil)
        #expect(reads == initialReads)
        #expect(find("Expand Unregistered", in: view) == nil)
        try await folderAction("Show Unregistered Folders", project: "Atlas")
        #expect(reads == initialReads + ["/code/Studio/Atlas"])
        #expect(find("Expand Unregistered", in: view) != nil)
        try await folderAction("Hide Unregistered Folders", project: "Atlas")
        #expect(find("Expand Unregistered", in: view) == nil)
        #expect(find("Expand Notes", in: view) != nil)
        #expect(opens == 0)
        if registeredAncestor, let directory = ProcessInfo.processInfo
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
        try await folderAction("Show Unregistered Folders", project: "Docs")
        #expect(reads == initialReads + ["/code/Studio/Atlas", "/code/Studio/Atlas/Docs"])
        try await press("Collapse Atlas")
        #expect(find("Expand Notes", in: view) == nil)
        try await press("Expand Atlas")
        #expect(find("Expand Notes", in: view) != nil)
        #expect(reads.filter { $0 == "/code/Studio/Atlas" }.count == 1)
        if registeredAncestor {
            try await press("Collapse Studio")
            try await press("Expand Studio")
            #expect(reads.filter { $0 == "/code/Studio" }.count == 1)
        }
        #expect(find("Collapse Atlas", in: view) != nil)
        #expect(find("Collapse Docs", in: view) != nil)
        #expect(find("Expand Notes", in: view) != nil)
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
