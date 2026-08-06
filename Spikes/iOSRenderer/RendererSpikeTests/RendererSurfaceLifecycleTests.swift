import GhosttyKit
import Testing
import UIKit
@testable import RendererSpike

@Suite("Renderer surface lifecycle")
struct RendererSurfaceLifecycleTests {
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
}
