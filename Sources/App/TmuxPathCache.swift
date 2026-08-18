import Foundation

/// Memoizes a tmux binary resolution, but only for a successful result.
///
/// `TmuxBinaryResolver.resolveTmuxBinary()` shells out to the login shell,
/// which is worth caching for the lifetime of the coordinator. A failure
/// (tmux not on PATH) must NOT be cached the same way: installing tmux after
/// the first failed resolve (`brew install tmux`) should be picked up on the
/// next resolve instead of requiring an app restart.
/// Concurrent callers share the active result, including a failure, without
/// retaining that failure for later calls. A cancelled active result does not
/// cancel callers that are still waiting for tmux.
///
/// Lock-guarded and `Sendable` so the first (blocking) resolve can run off the
/// main actor — a slow login shell must never beachball the UI on first open.
final class TmuxPathCache: @unchecked Sendable {
    private final class Resolution: @unchecked Sendable {
        private let condition = NSCondition()
        private var result:
            Result<ResolvedTmuxBinary, TmuxBinaryError>?

        func wait() -> Result<ResolvedTmuxBinary, TmuxBinaryError> {
            condition.lock()
            defer { condition.unlock() }
            while result == nil {
                condition.wait()
            }
            return result!
        }

        func complete(
            with result: Result<ResolvedTmuxBinary, TmuxBinaryError>
        ) {
            condition.lock()
            self.result = result
            condition.broadcast()
            condition.unlock()
        }
    }

    private let lock = NSLock()
    private var cachedBinary: ResolvedTmuxBinary?
    private var activeResolution: Resolution?
    private let cancellationShell: String
    private let resolve:
        @Sendable () -> Result<ResolvedTmuxBinary, TmuxBinaryError>

    init(
        cancellationShell: String = AccountCommandRunner.loginShell(),
        resolve: @escaping @Sendable ()
            -> Result<ResolvedTmuxBinary, TmuxBinaryError>
    ) {
        self.cancellationShell = cancellationShell
        self.resolve = resolve
    }

    func resolveTmuxBinary()
        -> Result<ResolvedTmuxBinary, TmuxBinaryError> {
        while true {
            lock.lock()
            if let cachedBinary {
                lock.unlock()
                return .success(cachedBinary)
            }
            if isCurrentTaskCancelled {
                lock.unlock()
                return cancellationFailure
            }
            if let activeResolution {
                lock.unlock()
                let result = activeResolution.wait()
                if case .failure(.probeCancelled) = result,
                   !isCurrentTaskCancelled {
                    continue
                }
                return result
            }
            let resolution = Resolution()
            activeResolution = resolution
            lock.unlock()

            guard !isCurrentTaskCancelled else {
                let result = cancellationFailure
                finish(resolution, with: result)
                return result
            }
            let resolved = resolve()
            finish(resolution, with: resolved)
            return resolved
        }
    }

    private var isCurrentTaskCancelled: Bool {
        withUnsafeCurrentTask { task in
            task?.isCancelled == true
        }
    }

    private var cancellationFailure:
        Result<ResolvedTmuxBinary, TmuxBinaryError> {
        .failure(.probeCancelled(shell: cancellationShell))
    }

    private func finish(
        _ resolution: Resolution,
        with result: Result<ResolvedTmuxBinary, TmuxBinaryError>
    ) {
        lock.lock()
        if case let .success(binary) = result {
            cachedBinary = binary
        }
        if activeResolution === resolution {
            activeResolution = nil
        }
        lock.unlock()
        resolution.complete(with: result)
    }
}
