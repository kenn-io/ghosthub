import Combine
import Foundation
import GhosthubTerminalSupport
import GhosthubWorkspace

@MainActor
public final class GhosttyRuntime: ObservableObject {
    public static let shared = GhosttyRuntime(
        pipeline: GhosttyConfigPipeline(
            paths: GhosttyConfigPaths(
                configDirectory: ConfigHome.resolved()
            )
        )
    )

    @Published public private(set) var bootstrapStatus: GhosttyBootstrapStatus
    @Published public private(set) var phase: GhosttyRuntimePhase
    @Published public private(set) var configPlan: GhosttyConfigLoadPlan?
    @Published public private(set) var diagnostics: [String]

    public let runtimeState: GhosttyRuntimeState
    public let renderTracker = SurfaceRenderTracker()

    private let pipeline: GhosttyConfigPipeline
    private var activeConfigRoot: URL?
    private var configMonitor: GhosttyConfigFileMonitor?

    public var configPaths: GhosttyConfigPaths {
        pipeline.paths
    }

    public var needsConfirmQuit: Bool { false }

    public init(
        pipeline: GhosttyConfigPipeline = .live,
        runtimeState: GhosttyRuntimeState? = nil,
        bootstrapStatus: GhosttyBootstrapStatus = .missing()
    ) {
        self.pipeline = pipeline
        self.runtimeState = runtimeState ?? GhosttyRuntimeState()
        self.bootstrapStatus = bootstrapStatus
        phase = .unavailable
        diagnostics = bootstrapStatus.message.map { [$0] } ?? []
        configPlan = try? pipeline.loadPlan()
        installConfigMonitorIfNeeded()
    }

    public func preconditionReady(file: StaticString = #file, line: UInt = #line) {
        preconditionFailure(
            bootstrapStatus.message ?? GhosttyBootstrapSupport.missingArtifactsMessage,
            file: file,
            line: line
        )
    }

    public func reloadConfig(projectRoot: URL? = nil, force: Bool = false) {
        guard force || activeConfigRoot != projectRoot else { return }
        activeConfigRoot = projectRoot
        configPlan = try? pipeline.loadPlan(projectRoot: projectRoot)
    }

    public func reloadActiveConfig(force: Bool = true) {
        reloadConfig(projectRoot: activeConfigRoot, force: force)
    }

    private func installConfigMonitorIfNeeded() {
        guard configMonitor == nil else { return }

        let monitor = GhosttyConfigFileMonitor(fileURL: configPaths
            .globalConfigFile) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.reloadConfig(projectRoot: self.activeConfigRoot, force: true)
                }
            }

        do {
            try monitor.start()
            configMonitor = monitor
        } catch {
            diagnostics.append(error.localizedDescription)
        }
    }
}
