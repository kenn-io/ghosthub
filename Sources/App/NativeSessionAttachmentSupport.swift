import Foundation
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubWorkspace

@MainActor
protocol NativeSessionPaneSurfacing: AnyObject {
    var blocksClipboardReads: Bool { get set }
    var paneSplitShortcutHandler: ((TerminalPaneSplitShortcut) -> Void)? {
        get set
    }
    var paneSplitErrorMessage: String? { get set }
    var hasEffectiveKeyboardFocus: Bool { get }
    var launchError: Error? { get }
    /// True when `launchError` describes a transient condition that a later
    /// attach can recover from, rather than a rejected launch.
    var launchFailureIsRetryable: Bool { get }
    var childExitCode: UInt32? { get }
    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool, UInt32?) -> Void
    )
}

extension NativeSessionPaneSurfacing {
    var paneSplitShortcutHandler: ((TerminalPaneSplitShortcut) -> Void)? {
        get { nil }
        set {}
    }

    var paneSplitErrorMessage: String? {
        get { nil }
        set {}
    }

    var hasEffectiveKeyboardFocus: Bool { false }

    var launchFailureIsRetryable: Bool { false }
}

extension TerminalSurfaceView: NativeSessionPaneSurfacing {
    var launchError: Error? { error }

    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool, UInt32?) -> Void
    ) {
        registerSurfaceCloseObserver(id: id) { [weak self] processAlive in
            onSurfaceClosed(processAlive, self?.childExitCode)
        }
    }
}

@MainActor
protocol NativeSessionSurfaceStoring: AnyObject {
    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> NativeSessionPaneSurfacing?
    func paneSurfaceIfPresent(for key: SurfaceKey) -> NativeSessionPaneSurfacing?
    func surfaceIdentity(for key: SurfaceKey) -> UInt?
    func removeSurface(for key: SurfaceKey)
}

extension NativeSessionSurfaceStoring {
    func paneSurfaceIfPresent(for _: SurfaceKey) -> NativeSessionPaneSurfacing? {
        nil
    }

    func surfaceIdentity(for _: SurfaceKey) -> UInt? {
        nil
    }
}

extension TerminalSurfaceCoordinator: NativeSessionSurfaceStoring {
    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> NativeSessionPaneSurfacing? {
        surface(for: key, configuration: configuration)
    }

    func surfaceIdentity(for key: SurfaceKey) -> UInt? {
        surfaceIfPresent(for: key)?.surfaceIdentity
    }

    func paneSurfaceIfPresent(for key: SurfaceKey) -> NativeSessionPaneSurfacing? {
        surfaceIfPresent(for: key)
    }
}

struct RemoteExitStatusStore {
    let directory: URL

    init(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ghosthub-session-exit-\(UUID().uuidString)",
                isDirectory: true
            )
    ) {
        self.directory = directory
    }

    func prepare() -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let url = directory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: false
            )
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else { return nil }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return url
        } catch {
            return nil
        }
    }

    func consume(_ url: URL?) -> UInt32? {
        guard let url else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return UInt32(value)
    }

    func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
