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
    @Published public private(set) var configReloadNotice:
        LibghosttyConfigReloadNotice?

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
        configReloadNotice = nil
        configPlan = try? pipeline.loadPlan()
        installConfigMonitorIfNeeded(plan: configPlan)
    }

    public func preconditionReady(file: StaticString = #file, line: UInt = #line) {
        preconditionFailure(
            bootstrapStatus.message ?? LibghosttyBootstrapSupport.missingArtifactsMessage,
            file: file,
            line: line
        )
    }

    @discardableResult
    public func reloadConfig(
        projectRoot: URL? = nil,
        force: Bool = false
    ) -> LibghosttyConfigReloadResult {
        guard force || activeConfigRoot != projectRoot else {
            return .unchanged
        }
        activeConfigRoot = projectRoot
        configPlan = try? pipeline.loadPlan(projectRoot: projectRoot)
        if let configPlan {
            updateConfigMonitor(for: configPlan)
        }
        return .failed("libghostty is unavailable.")
    }

    @discardableResult
    public func reloadActiveConfig(
        force: Bool = true,
        notifyOnSuccess: Bool = true
    ) -> LibghosttyConfigReloadResult {
        reloadConfig(projectRoot: activeConfigRoot, force: force)
    }

    private func installConfigMonitorIfNeeded(
        plan: LibghosttyConfigLoadPlan?
    ) {
        guard configMonitor == nil else { return }
        guard let plan else { return }

        let monitor = LibghosttyConfigFileMonitor(
            fileURLs: plan.watchedConfigFiles,
            errorHandler: { [weak self] error in
                Task { @MainActor in
                    self?.diagnostics.append(error.localizedDescription)
                }
            }
        ) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.reloadActiveConfig(force: true)
                }
            }

        do {
            try monitor.start()
            configMonitor = monitor
        } catch {
            diagnostics.append(error.localizedDescription)
            configMonitor = monitor
        }
    }

    private func updateConfigMonitor(
        for plan: LibghosttyConfigLoadPlan
    ) {
        guard let configMonitor else {
            installConfigMonitorIfNeeded(plan: plan)
            return
        }
        do {
            try configMonitor.update(fileURLs: plan.watchedConfigFiles)
        } catch {
            diagnostics.append(error.localizedDescription)
        }
    }
}
