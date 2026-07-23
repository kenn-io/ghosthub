import Combine
import Foundation
import GhosthubTerminalSupport
import GhosthubWorkspace

@MainActor
public final class LibghosttyRuntime: ObservableObject {
    public static let shared = LibghosttyRuntime(
        pipeline: LibghosttyConfigPipeline(
            paths: LibghosttyConfigPaths(
                configDirectory: ConfigHome.resolved()
            )
        )
    )

    @Published public private(set) var bootstrapStatus: LibghosttyBootstrapStatus
    @Published public private(set) var phase: LibghosttyRuntimePhase
    @Published public private(set) var configPlan: LibghosttyConfigLoadPlan?
    @Published public private(set) var diagnostics: [String]

    public let runtimeState: LibghosttyRuntimeState
    public let renderTracker = SurfaceRenderTracker()

    private let pipeline: LibghosttyConfigPipeline
    private var activeConfigRoot: URL?
    private var configMonitor: LibghosttyConfigFileMonitor?

    public var configPaths: LibghosttyConfigPaths {
        pipeline.paths
    }

    public var needsConfirmQuit: Bool { false }

    public init(
        pipeline: LibghosttyConfigPipeline = .live,
        runtimeState: LibghosttyRuntimeState? = nil,
        bootstrapStatus: LibghosttyBootstrapStatus = .missing()
    ) {
        self.pipeline = pipeline
        self.runtimeState = runtimeState ?? LibghosttyRuntimeState()
        self.bootstrapStatus = bootstrapStatus
        phase = .unavailable
        diagnostics = bootstrapStatus.message.map { [$0] } ?? []
        configPlan = try? pipeline.loadPlan()
        installConfigMonitorIfNeeded()
    }

    public func preconditionReady(file: StaticString = #file, line: UInt = #line) {
        preconditionFailure(
            bootstrapStatus.message ?? LibghosttyBootstrapSupport.missingArtifactsMessage,
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

        let monitor = LibghosttyConfigFileMonitor(fileURL: configPaths
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
