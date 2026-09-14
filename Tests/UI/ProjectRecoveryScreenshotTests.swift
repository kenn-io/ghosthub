import AppKit
import Foundation
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubUI

@Suite("Project recovery documentation screenshot")
struct ProjectRecoveryScreenshotTests {
    @MainActor
    @Test("exports the Locate Folder sheet with synthetic project data")
    func locateFolderSheet() throws {
        guard let path = ProcessInfo.processInfo
            .environment["GHOSTHUB_PROJECT_RECOVERY_SCREENSHOT"] else { return }
        let host = HostSummary(
            id: UUID(), configKey: "local", name: "This Mac", kind: .selfHost,
            platform: .macOS, lastKnownReachable: true, tmuxSessions: []
        )
        let project = ProjectSummary(
            id: UUID(), hostID: host.id, scopedKey: "github.com/acme/widget",
            name: "Widget", rootPath: "/code/widget", pathIssue: .missing
        )
        let sheet = AddProjectSheet(
            host: host, recoveringProject: project,
            onAdd: { _ in .success("Widget") }, onCancel: {}, onAdded: {}
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        let view = hostView(AnyView(sheet), size: CGSize(width: 500, height: 300))
        let size = CGSize(width: 500, height: ceil(view.fittingSize.height))
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.close() }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
