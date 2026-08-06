import Combine
import Foundation
import GhosttyKit

enum RendererRuntimeError: LocalizedError {
    case applicationUnavailable
    case surfaceCreation

    var errorDescription: String? {
        switch self {
        case .applicationUnavailable:
            "The libghostty application is not ready."
        case .surfaceCreation:
            "ghostty_surface_new returned no surface."
        }
    }
}

private final class RendererHandles: @unchecked Sendable {
    var config: ghostty_config_t?
    var app: ghostty_app_t?

    func shutdown() {
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
        if let config {
            ghostty_config_free(config)
            self.config = nil
        }
    }

    deinit {
        shutdown()
    }
}

@MainActor
private final class RendererCallbackContext {
    weak var runtime: RendererRuntime?

    nonisolated func scheduleTick() {
        DispatchQueue.main.async { [weak self] in
            self?.runtime?.tick()
        }
    }
}

@MainActor
final class RendererRuntime: ObservableObject {
    @Published private(set) var status: RendererStatus = .idle

    private static var didInitializeLibrary = false

    private nonisolated let handles = RendererHandles()
    private let callbackContext = RendererCallbackContext()

    init() {
        callbackContext.runtime = self
    }

    var isApplicationReady: Bool {
        handles.app != nil
    }

    func start(resourceRoot: URL? = Bundle.main.resourceURL) {
        guard handles.app == nil, status == .idle else { return }

        guard let resourceRoot,
              Self.hasRequiredResources(at: resourceRoot)
        else {
            status = .failed(
                stage: .libraryReady,
                message: "The bundled ghostty and terminfo resources are unavailable."
            )
            return
        }

        let ghosttyResources = resourceRoot.appendingPathComponent(
            "ghostty",
            isDirectory: true
        )
        setenv("GHOSTTY_RESOURCES_DIR", ghosttyResources.path, 1)

        if !Self.didInitializeLibrary {
            let result = ghostty_init(
                UInt(CommandLine.argc),
                CommandLine.unsafeArgv
            )
            guard result == GHOSTTY_SUCCESS else {
                status = .failed(
                    stage: .libraryReady,
                    message: "ghostty_init failed with status \(result)."
                )
                return
            }
            Self.didInitializeLibrary = true
        }
        status = .libraryReady

        guard let config = ghostty_config_new() else {
            status = .failed(
                stage: .configReady,
                message: "ghostty_config_new returned no configuration."
            )
            return
        }
        ghostty_config_finalize(config)
        handles.config = config
        status = .configReady

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(callbackContext)
            .toOpaque()
        runtimeConfig.wakeup_cb = rendererSpikeWakeup
        runtimeConfig.action_cb = rendererSpikeAction
        runtimeConfig.read_clipboard_cb = rendererSpikeReadClipboard
        runtimeConfig.confirm_read_clipboard_cb = rendererSpikeConfirmReadClipboard
        runtimeConfig.write_clipboard_cb = rendererSpikeWriteClipboard
        runtimeConfig.close_surface_cb = rendererSpikeCloseSurface
        runtimeConfig.child_write_cb = rendererSpikeChildWrite

        guard let app = ghostty_app_new(&runtimeConfig, config) else {
            ghostty_config_free(config)
            handles.config = nil
            status = .failed(
                stage: .appReady,
                message: "ghostty_app_new returned no application."
            )
            return
        }
        handles.app = app
        status = .appReady
    }

    func createSurface(
        configuration: inout ghostty_surface_config_s
    ) throws -> ghostty_surface_t {
        guard let appHandle = handles.app else {
            throw RendererRuntimeError.applicationUnavailable
        }
        guard let surface = ghostty_surface_new(appHandle, &configuration) else {
            status = .failed(
                stage: .surfaceReady,
                message: RendererRuntimeError.surfaceCreation.localizedDescription
            )
            throw RendererRuntimeError.surfaceCreation
        }
        status = .surfaceReady
        return surface
    }

    func markRendered() {
        status = .rendered
    }

    func surfaceDidClose() {
        guard handles.app != nil else { return }
        status = .appReady
    }

    func reportSurfaceFailure(_ error: Error) {
        status = .failed(
            stage: .surfaceReady,
            message: error.localizedDescription
        )
    }

    func shutdown() {
        handles.shutdown()
        status = .idle
    }

    fileprivate func tick() {
        guard let appHandle = handles.app else { return }
        ghostty_app_tick(appHandle)
    }

    private static func hasRequiredResources(at root: URL) -> Bool {
        let ghostty = root.appendingPathComponent("ghostty", isDirectory: true)
        let terminfo = root.appendingPathComponent(
            "terminfo/78/xterm-ghostty",
            isDirectory: false
        )
        return FileManager.default.fileExists(atPath: ghostty.path)
            && FileManager.default.fileExists(atPath: terminfo.path)
    }
}

private func rendererSpikeWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let context = Unmanaged<RendererCallbackContext>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    context.scheduleTick()
}

private func rendererSpikeAction(
    _: ghostty_app_t?,
    _: ghostty_target_s,
    _: ghostty_action_s
) -> Bool {
    false
}

private func rendererSpikeReadClipboard(
    _: UnsafeMutableRawPointer?,
    _: ghostty_clipboard_e,
    _: UnsafeMutableRawPointer?
) -> Bool {
    false
}

private func rendererSpikeConfirmReadClipboard(
    _: UnsafeMutableRawPointer?,
    _: UnsafePointer<CChar>?,
    _: UnsafeMutableRawPointer?,
    _: ghostty_clipboard_request_e
) {}

private func rendererSpikeWriteClipboard(
    _: UnsafeMutableRawPointer?,
    _: ghostty_clipboard_e,
    _: UnsafePointer<ghostty_clipboard_content_s>?,
    _: Int,
    _: Bool
) {}

private func rendererSpikeCloseSurface(
    _: UnsafeMutableRawPointer?,
    _: Bool
) {}

private func rendererSpikeChildWrite(
    _: UnsafeMutableRawPointer?,
    _: UnsafePointer<CChar>?,
    _: UInt
) {}
