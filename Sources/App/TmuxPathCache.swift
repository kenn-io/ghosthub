import Foundation

/// Memoizes a tmux-path resolution, but only for a successful result.
///
/// `TmuxBinaryResolver.resolveTmuxPath()` shells out to the login shell,
/// which is worth caching for the lifetime of the coordinator. A failure
/// (tmux not on PATH) must NOT be cached the same way: installing tmux after
/// the first failed resolve (`brew install tmux`) should be picked up on the
/// next resolve instead of requiring an app restart.
///
/// Lock-guarded and `Sendable` so the first (blocking) resolve can run off the
/// main actor — a slow login shell must never beachball the UI on first open.
final class TmuxPathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedPath: String?
    private let resolve: @Sendable () -> Result<String, TmuxBinaryError>

    init(resolve: @escaping @Sendable () -> Result<String, TmuxBinaryError>) {
        self.resolve = resolve
    }

    func resolveTmuxPath() -> Result<String, TmuxBinaryError> {
        lock.lock()
        if let cachedPath {
            lock.unlock()
            return .success(cachedPath)
        }
        lock.unlock()
        let resolved = resolve()
        if case let .success(path) = resolved {
            lock.lock()
            cachedPath = path
            lock.unlock()
        }
        return resolved
    }
}
