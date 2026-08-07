import AppKit
import Foundation
import GhosthubSettings
import GhosthubWorkspace
import SwiftUI
import Testing
import Vision
@testable import GhosthubUI

@Suite("Launch profile documentation screenshot")
struct LaunchProfileScreenshotTests {
    @MainActor
    @Test("exports the real sheet with a deterministic selected profile")
    func selectedProfileRenders() throws {
        guard let outputPath = ProcessInfo.processInfo.environment[
            "GHOSTHUB_LAUNCH_PROFILE_SCREENSHOT"
        ] else {
            return
        }
        let hostID = try #require(
            UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        )
        let profileID = try #require(
            UUID(uuidString: "11111111-2222-4333-8444-555555555555")
        )
        let host = HostSummary(
            id: hostID,
            configKey: "gpu-01",
            name: "gpu-01",
            kind: .remote,
            platform: .linux,
            sshDestination: "ghosthub-demo-remote",
            preferredTransport: .ssh,
            lastKnownReachable: true,
            tmuxSessions: []
        )
        let configuredHost = SSHHost(
            configKey: "gpu-01",
            name: "gpu-01",
            platform: .linux,
            sshDestination: "ghosthub-demo-remote",
            launchProfiles: [
                TmuxLaunchProfile(
                    id: profileID,
                    name: "Container shell",
                    command: "docker exec -it app-container /bin/sh"
                ),
            ]
        )
        let sheet = NewTmuxSessionSheet(
            host: host,
            hosts: [host],
            configuredHosts: [configuredHost],
            selectedProfileID: profileID,
            onCreate: { _, _, _ in },
            onCancel: {}
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        let hostingView = hostView(AnyView(sheet), size: CGSize(
            width: 500,
            height: 260
        ))
        let fittingHeight = ceil(hostingView.fittingSize.height)
        let renderSize = CGSize(width: 500, height: fittingHeight)
        hostingView.frame = NSRect(
            origin: .zero,
            size: renderSize
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: renderSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.close() }
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        hostingView.displayIfNeeded()

        let size = hostingView.bounds.size
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        hostingView.displayIgnoringOpacity(hostingView.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        let png = try #require(bitmap.representation(
            using: NSBitmapImageRep.FileType.png,
            properties: [:]
        ))
        #expect(bitmap.pixelsWide == 1000)
        #expect(bitmap.pixelsHigh > 0)
        #expect(!png.isEmpty)

        let image = try #require(bitmap.cgImage)
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: image).perform([textRequest])
        let recognizedText = (textRequest.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        #expect(recognizedText.contains {
            $0.localizedCaseInsensitiveContains("Container shell")
        })
        try png.write(
            to: URL(fileURLWithPath: outputPath),
            options: Data.WritingOptions.atomic
        )
    }
}
