import GhosttyKit
import QuartzCore
import SwiftUI
import UIKit

final class SurfaceHandleOwner: @unchecked Sendable {
    private(set) var handle: ghostty_surface_t?
    private let destroy: (ghostty_surface_t) -> Void

    init(destroy: @escaping (ghostty_surface_t) -> Void = ghostty_surface_free) {
        self.destroy = destroy
    }

    func replace(with handle: ghostty_surface_t) {
        clear()
        self.handle = handle
    }

    func clear() {
        guard let handle else { return }
        self.handle = nil
        destroy(handle)
    }

    deinit {
        clear()
    }
}

@MainActor
final class RendererSurfaceBridge: ObservableObject {
    private weak var view: RendererSurfaceView?

    func connect(_ view: RendererSurfaceView) {
        self.view = view
    }

    func reset() {
        view?.resetSurface()
    }

    func destroy() {
        view?.destroySurface()
    }
}

@MainActor
final class RendererSurfaceView: UIView {
    private let runtime: RendererRuntime
    private let surface = SurfaceHandleOwner()

    init(runtime: RendererRuntime) {
        self.runtime = runtime
        super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        backgroundColor = .black
        isOpaque = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSurfaceGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateSurfaceGeometry()
    }

    func ensureSurface() {
        guard surface.handle == nil, runtime.isApplicationReady else { return }
        createSurface()
    }

    func resetSurface() {
        guard runtime.isApplicationReady else { return }
        destroySurface()
        createSurface()
    }

    func destroySurface() {
        guard surface.handle != nil else { return }
        surface.clear()
        runtime.surfaceDidClose()
    }

    private func createSurface() {
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_IOS
        config.platform = ghostty_platform_u(
            ios: ghostty_platform_ios_s(
                uiview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        config.scale_factor = Double(displayScale)
        config.external_io = true

        do {
            let handle = try runtime.createSurface(configuration: &config)
            surface.replace(with: handle)
            updateSurfaceGeometry()
            injectReferenceTranscript(into: handle)
            runtime.markRendered()
        } catch {
            runtime.reportSurfaceFailure(error)
        }
    }

    private func updateSurfaceGeometry() {
        guard let handle = surface.handle else { return }
        let scale = displayScale
        contentScaleFactor = scale
        layer.contentsScale = scale
        ghostty_surface_set_content_scale(handle, Double(scale), Double(scale))
        ghostty_surface_set_size(
            handle,
            UInt32(max(1, (bounds.width * scale).rounded())),
            UInt32(max(1, (bounds.height * scale).rounded()))
        )
    }

    private func injectReferenceTranscript(into handle: ghostty_surface_t) {
        ReferenceTranscript.bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ghostty_surface_inject_output(
                handle,
                UnsafeRawPointer(baseAddress).assumingMemoryBound(to: CChar.self),
                UInt(buffer.count)
            )
        }
    }

    private var displayScale: CGFloat {
        window?.screen.scale ?? traitCollection.displayScale
    }
}

struct RendererSurfaceHost: UIViewRepresentable {
    let runtime: RendererRuntime
    let bridge: RendererSurfaceBridge

    func makeUIView(context _: Context) -> RendererSurfaceView {
        let view = RendererSurfaceView(runtime: runtime)
        bridge.connect(view)
        view.ensureSurface()
        return view
    }

    func updateUIView(_ view: RendererSurfaceView, context _: Context) {
        view.ensureSurface()
    }

    static func dismantleUIView(_ view: RendererSurfaceView, coordinator _: Void) {
        view.destroySurface()
    }
}
