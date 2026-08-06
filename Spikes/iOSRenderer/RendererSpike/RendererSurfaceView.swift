import GhosttyKit
import QuartzCore
import SwiftUI
import UIKit

@MainActor
final class RendererSurfaceCallbackContext {
    private weak var view: RendererSurfaceView?

    init(view: RendererSurfaceView) {
        self.view = view
    }

    nonisolated func receive(_ data: Data) {
        Task { @MainActor [self] in
            view?.receiveChildWrite(data, from: self)
        }
    }
}

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
final class RendererSurfaceView: UIView, UIKeyInput {
    private let runtime: RendererRuntime
    private let surface = SurfaceHandleOwner()
    private var callbackContext: RendererSurfaceCallbackContext?
    private var handledPresses: Set<ObjectIdentifier> = []

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

    override var canBecomeFirstResponder: Bool {
        true
    }

    var hasText: Bool {
        true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSurfaceGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateSurfaceGeometry()
        if let handle = surface.handle {
            ghostty_surface_set_focus(handle, window != nil)
        }
        if window != nil {
            becomeFirstResponder()
        }
    }

    func insertText(_ text: String) {
        guard let route = IOSKeyboardMapper.textInputRoute(text) else { return }
        send(route)
    }

    func deleteBackward() {
        let route = IOSKeyboardMapper.deleteRoute()
        send(route)
        send(route, action: GHOSTTY_ACTION_RELEASE)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        becomeFirstResponder()
        super.touchesBegan(touches, with: event)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var forwarded = presses
        for press in presses {
            guard let route = route(for: press) else { continue }
            guard route != .deferToTextInput else { continue }
            handledPresses.insert(ObjectIdentifier(press))
            forwarded.remove(press)
            send(route)
        }
        if !forwarded.isEmpty {
            super.pressesBegan(forwarded, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        finish(presses: presses, event: event, cancelled: false)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        finish(presses: presses, event: event, cancelled: true)
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
        callbackContext = nil
        handledPresses.removeAll()
        runtime.surfaceDidClose()
    }

    func send(
        _ route: IOSKeyboardRoute,
        action: ghostty_input_action_e = GHOSTTY_ACTION_PRESS
    ) {
        guard let handle = surface.handle else { return }
        switch route {
        case .deferToTextInput:
            return
        case let .text(text):
            guard action == GHOSTTY_ACTION_PRESS else { return }
            text.withCString { pointer in
                ghostty_surface_text(handle, pointer, UInt(text.utf8.count))
            }
        case let .key(key):
            var event = ghostty_input_key_s()
            event.action = action
            event.mods = key.modifiers
            let translation = ghostty_surface_key_translation_mods(
                handle,
                key.modifiers
            )
            let nonTextModifiers = GHOSTTY_MODS_CTRL.rawValue
                | GHOSTTY_MODS_SUPER.rawValue
            event.consumed_mods = ghostty_input_mods_e(
                translation.rawValue & ~nonTextModifiers
            )
            event.keycode = key.keycode
            event.unshifted_codepoint = key.unshiftedCodepoint
            event.composing = false
            if let text = key.text, action != GHOSTTY_ACTION_RELEASE {
                text.withCString { pointer in
                    event.text = pointer
                    _ = ghostty_surface_key(handle, event)
                }
            } else {
                event.text = nil
                _ = ghostty_surface_key(handle, event)
            }
        }
    }

    func receiveChildWrite(
        _ data: Data,
        from context: RendererSurfaceCallbackContext
    ) {
        guard callbackContext === context, let handle = surface.handle else { return }
        runtime.recordChildWrite(data)
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ghostty_surface_inject_output(
                handle,
                baseAddress.assumingMemoryBound(to: CChar.self),
                UInt(buffer.count)
            )
        }
    }

    private func createSurface() {
        let context = RendererSurfaceCallbackContext(view: self)
        callbackContext = context
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(context).toOpaque()
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
            callbackContext = nil
            runtime.reportSurfaceFailure(error)
        }
    }

    private func route(for press: UIPress) -> IOSKeyboardRoute? {
        guard let key = press.key else { return nil }
        return IOSKeyboardMapper.pressRoute(
            usage: key.keyCode,
            characters: key.characters,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifiers: key.modifierFlags
        )
    }

    private func finish(
        presses: Set<UIPress>,
        event: UIPressesEvent?,
        cancelled: Bool
    ) {
        var forwarded = presses
        for press in presses where handledPresses.remove(ObjectIdentifier(press)) != nil {
            forwarded.remove(press)
            if let route = route(for: press) {
                send(route, action: GHOSTTY_ACTION_RELEASE)
            }
        }
        guard !forwarded.isEmpty else { return }
        if cancelled {
            super.pressesCancelled(forwarded, with: event)
        } else {
            super.pressesEnded(forwarded, with: event)
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
