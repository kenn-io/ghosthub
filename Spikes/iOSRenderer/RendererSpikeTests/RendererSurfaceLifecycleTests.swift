import GhosttyKit
import Testing
import UIKit
@testable import RendererSpike

@Suite("Renderer surface lifecycle")
struct RendererSurfaceLifecycleTests {
    @Test("live text and arrow input return through child-write")
    @MainActor
    func liveInputLoopback() async throws {
        let runtime = RendererRuntime()
        runtime.start()
        let surface = RendererSurfaceView(runtime: runtime)
        surface.ensureSurface()

        surface.send(.text("loopback"))
        try await waitForBytes(Array("loopback".utf8), from: runtime)

        let arrow = IOSKeyboardMapper.pressRoute(
            usage: .keyboardLeftArrow,
            characters: UIKeyCommand.inputLeftArrow,
            charactersIgnoringModifiers: UIKeyCommand.inputLeftArrow,
            modifiers: []
        )
        if let arrow {
            surface.send(arrow)
        }
        try await waitForBytes([0x1B, 0x5B, 0x44], from: runtime)

        surface.destroySurface()
        runtime.shutdown()
    }

    @Test("live surface renders, resizes, and resets repeatedly")
    @MainActor
    func liveSurfaceLifecycle() {
        let runtime = RendererRuntime()
        runtime.start()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let viewController = UIViewController()
        let surface = RendererSurfaceView(runtime: runtime)
        viewController.view = surface
        window.rootViewController = viewController
        window.makeKeyAndVisible()

        surface.ensureSurface()
        #expect(runtime.status == .rendered)

        for width in [900.0, 700.0, 1100.0] {
            surface.frame.size = CGSize(width: width, height: 600)
            surface.layoutIfNeeded()
            surface.resetSurface()
            #expect(runtime.status == .rendered)
        }

        surface.destroySurface()
        #expect(runtime.status == .appReady)
        runtime.shutdown()
    }

    @Test("replacement and repeated clearing destroy each surface once")
    func replacementAndClearing() {
        var destroyed: [UInt] = []
        let owner = SurfaceHandleOwner { handle in
            destroyed.append(UInt(bitPattern: handle))
        }
        let first = UnsafeMutableRawPointer(bitPattern: 1)!
        let second = UnsafeMutableRawPointer(bitPattern: 2)!

        owner.replace(with: first)
        owner.replace(with: second)
        owner.clear()
        owner.clear()

        #expect(destroyed == [1, 2])
    }

    @Test("deinitialization destroys a retained surface")
    func deinitialization() {
        var destroyed: [UInt] = []
        var owner: SurfaceHandleOwner? = SurfaceHandleOwner { handle in
            destroyed.append(UInt(bitPattern: handle))
        }
        owner?.replace(with: UnsafeMutableRawPointer(bitPattern: 7)!)

        owner = nil

        #expect(destroyed == [7])
    }

    @MainActor
    private func waitForBytes(
        _ expected: [UInt8],
        from runtime: RendererRuntime
    ) async throws {
        for _ in 0 ..< 100 {
            if runtime.lastChildWrite == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record(
            "Expected child-write bytes \(expected), got \(runtime.lastChildWrite)"
        )
    }
}
