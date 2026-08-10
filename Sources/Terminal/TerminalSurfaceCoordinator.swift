import Foundation
import GhosthubTerminalSupport
import GhosthubWorkspace

@MainActor
public final class TerminalSurfaceCoordinator: ObservableObject {
    private let runtime: LibghosttyRuntime
    private var surfaces: [SurfaceKey: TerminalSurfaceView] = [:]
    private var surfaceKeyMap: [ObjectIdentifier: SurfaceKey] = [:]
    private var surfaceIdentityMap: [UInt: SurfaceKey] = [:]
    private var fontZoomOverridePoints: CGFloat?

    public var onSurfaceCreated: ((SurfaceKey, TerminalSurfaceView) -> Void)?
    public var applicationShortcutsProvider:
        (() -> ResolvedApplicationShortcuts)?

    public init(runtime: LibghosttyRuntime) {
        self.runtime = runtime
    }

    public func surface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> TerminalSurfaceView? {
        if let existing = surfaces[key] {
            if existing.error == nil {
                return existing
            }
            // Surface was closed — evict and recreate below.
            removeMappings(for: existing)
            surfaces.removeValue(forKey: key)
        }

        guard let appHandle = runtime.unsafeAppHandle else {
            return nil
        }

        var configuration = configuration
        if let fontZoomOverridePoints {
            configuration.fontSize = fontZoomOverridePoints
        }

        let view = TerminalSurfaceView(
            app: appHandle,
            configuration: configuration
        )
        view.applicationShortcutsProvider = applicationShortcutsProvider
        view.onSurfaceDestroyed = { [weak runtime] identity in
            runtime?.unregisterSurfaceForResolvedColors(identity)
        }
        view.fontZoomShortcutHandler = { [weak self] command in
            self?.applyFontZoom(command)
            return true
        }
        if let fontZoomOverridePoints {
            _ = view.performBindingAction(
                TerminalFontZoomCommand.setFontSizeAction(
                    points: fontZoomOverridePoints
                )
            )
        }
        surfaces[key] = view
        surfaceKeyMap[ObjectIdentifier(view)] = key
        if let surface = view.surfaceHandle {
            let identity = UInt(bitPattern: surface)
            surfaceIdentityMap[identity] = key
            view.synchronizeColorScheme()
            runtime.registerSurfaceForResolvedColors(surface)
        }
        onSurfaceCreated?(key, view)
        return view
    }

    public func surfaceKey(
        for surfaceView: TerminalSurfaceView
    ) -> SurfaceKey? {
        surfaceKeyMap[ObjectIdentifier(surfaceView)]
    }

    public func surfaceKey(
        forSurfaceIdentity identity: UInt
    ) -> SurfaceKey? {
        surfaceIdentityMap[identity]
    }

    public func containsSurface(for key: SurfaceKey) -> Bool {
        surfaces[key] != nil
    }

    public func surfaceIfPresent(
        for key: SurfaceKey
    ) -> TerminalSurfaceView? {
        surfaces[key]
    }

    public func surfaceEntries() -> [(key: SurfaceKey, view: TerminalSurfaceView)] {
        surfaces.map { (key: $0.key, view: $0.value) }
    }

    public func removeSurface(for key: SurfaceKey) {
        if let view = surfaces[key] {
            removeMappings(for: view)
        }
        surfaces.removeValue(forKey: key)
    }

    public func removeWorktreeSurfaces(worktreeID: UUID) {
        let keysToRemove = surfaces.keys.filter {
            $0.worktreeID == worktreeID
        }
        for key in keysToRemove {
            if let view = surfaces[key] {
                removeMappings(for: view)
            }
            surfaces.removeValue(forKey: key)
        }
    }

    public func removeConsoleSurfaces(hostID: UUID) {
        let keysToRemove = surfaces.keys.filter {
            $0.target == .console && $0.hostID == hostID
        }
        for key in keysToRemove {
            if let view = surfaces[key] {
                removeMappings(for: view)
            }
            surfaces.removeValue(forKey: key)
        }
    }

    public func removeAll() {
        for view in surfaces.values {
            removeMappings(for: view)
        }
        surfaceKeyMap.removeAll()
        surfaceIdentityMap.removeAll()
        surfaces.removeAll()
    }

    func applyFontZoom(_ command: TerminalFontZoomCommand) {
        fontZoomOverridePoints = updatedFontZoomOverridePoints(
            for: command
        )
        let action = command.bindingAction(
            overridePoints: fontZoomOverridePoints
        )

        for view in surfaces.values {
            guard view.performBindingAction(action) else { continue }
            view.refreshGridSize()
        }
    }

    private func removeMappings(for view: TerminalSurfaceView) {
        surfaceKeyMap.removeValue(forKey: ObjectIdentifier(view))
        if let identity = view.surfaceIdentity {
            surfaceIdentityMap.removeValue(forKey: identity)
            runtime.unregisterSurfaceForResolvedColors(identity)
        }
    }

    private func referenceSurfaceForFontZoomOverride() -> TerminalSurfaceView? {
        surfaces.values.first(where: { $0.focused && $0.currentFontSizePoints != nil })
            ?? surfaces.values.first(where: { $0.currentFontSizePoints != nil })
    }

    private func updatedFontZoomOverridePoints(
        for command: TerminalFontZoomCommand
    ) -> CGFloat? {
        switch command {
        case .reset:
            return nil
        case .increase:
            let current = fontZoomOverridePoints
                ?? referenceSurfaceForFontZoomOverride()?.currentFontSizePoints
            return current.map { $0 + 1 }
        case .decrease:
            let current = fontZoomOverridePoints
                ?? referenceSurfaceForFontZoomOverride()?.currentFontSizePoints
            return current.map { max(1, $0 - 1) }
        }
    }
}
