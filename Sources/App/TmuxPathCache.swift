import Foundation

/// Memoizes a tmux binary resolution, but only for a successful result.
///
/// `TmuxBinaryResolver.resolveTmuxBinary()` shells out to the login shell,
/// which is worth caching for the lifetime of the coordinator. A failure
/// (tmux not on PATH) must NOT be cached the same way: installing tmux after
/// the first failed resolve (`brew install tmux`) should be picked up on the
/// next resolve instead of requiring an app restart.
///
/// Lock-guarded and `Sendable` so the first (blocking) resolve can run off the
/// main actor — a slow login shell must never beachball the UI on first open.
final class TmuxPathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedBinary: ResolvedTmuxBinary?
    private let resolve:
        @Sendable () -> Result<ResolvedTmuxBinary, TmuxBinaryError>

    init(
        resolve: @escaping @Sendable ()
            -> Result<ResolvedTmuxBinary, TmuxBinaryError>
    ) {
        self.resolve = resolve
    }

    func resolveTmuxBinary()
        -> Result<ResolvedTmuxBinary, TmuxBinaryError> {
        lock.lock()
        defer { lock.unlock() }
        if let cachedBinary {
            return .success(cachedBinary)
        }
        let resolved = resolve()
        if case let .success(binary) = resolved {
            cachedBinary = binary
        }
        return resolved
    }
}
