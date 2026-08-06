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
        let surface = RendererSurfaceView(
            runtime: runtime,
            bridge: RendererSurfaceBridge()
        )
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

        let functionKey = IOSKeyboardMapper.pressRoute(
            usage: .keyboardF1,
            characters: "",
            charactersIgnoringModifiers: "",
            modifiers: []
        )
        if let functionKey {
            surface.send(functionKey)
        }
        try await waitForBytes([0x1B, 0x4F, 0x50], from: runtime)

        let home = IOSKeyboardMapper.pressRoute(
            usage: .keyboardHome,
            characters: "",
            charactersIgnoringModifiers: "",
            modifiers: []
        )
        if let home {
            surface.send(home)
        }
        try await waitForBytes([0x1B, 0x5B, 0x48], from: runtime)

        let controlA = IOSKeyboardMapper.pressRoute(
            usage: .keyboardA,
            characters: "\u{01}",
            charactersIgnoringModifiers: "a",
            modifiers: .control
        )
        if let controlA {
            surface.send(controlA)
        }
        try await waitForBytes([0x01], from: runtime)

        let optionD = IOSKeyboardMapper.pressRoute(
            usage: .keyboardD,
            characters: "∂",
            charactersIgnoringModifiers: "d",
            modifiers: .alternate
        )
        if let optionD {
            surface.send(optionD)
        }
        try await waitForBytes(Array("∂".utf8), from: runtime)

        surface.destroySurface()
        runtime.shutdown()
    }

    @Test("live surface renders, resizes, and resets repeatedly")
    @MainActor
    func liveSurfaceLifecycle() async throws {
        let runtime = RendererRuntime()
        runtime.start()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let viewController = UIViewController()
        let surface = RendererSurfaceView(
            runtime: runtime,
            bridge: RendererSurfaceBridge()
        )
        viewController.view = surface
        window.rootViewController = viewController
        window.makeKeyAndVisible()

        surface.ensureSurface()
        try await waitForRendered(runtime)
        let rendererSublayerCount = surface.rendererSublayerCount
        #expect(rendererSublayerCount > 0)

        for width in [900.0, 700.0, 1100.0] {
            surface.frame.size = CGSize(width: width, height: 600)
            surface.layoutIfNeeded()
            surface.resetSurface()
            try await waitForRendered(runtime)
            #expect(surface.rendererSublayerCount == rendererSublayerCount)
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

    @Test("runtime shutdown frees live surfaces before the application")
    @MainActor
    func runtimeShutdownBeforeViewTeardown() {
        let runtime = RendererRuntime()
        runtime.start()
        let surface = RendererSurfaceView(
            runtime: runtime,
            bridge: RendererSurfaceBridge()
        )
        surface.ensureSurface()

        runtime.shutdown()
        surface.destroySurface()

        #expect(runtime.status == .idle)
        #expect(surface.rendererSublayerCount == 0)
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

    @MainActor
    private func waitForRendered(_ runtime: RendererRuntime) async throws {
        for _ in 0 ..< 500 {
            if runtime.status == .rendered {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Expected a presented Metal frame, got \(runtime.status)")
    }
}
