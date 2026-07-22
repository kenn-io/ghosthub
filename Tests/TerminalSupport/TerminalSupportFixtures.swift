import Combine
import Foundation

/// Collects events emitted synchronously by a `PassthroughSubject`
/// during `action`. Only safe for subjects that deliver on the
/// caller's thread; do not use with `receive(on:)` or async publishers.
func collectEvents<Output>(
    from subject: PassthroughSubject<Output, Never>,
    performing action: () -> Void
) -> [Output] {
    var received: [Output] = []
    let cancellable = subject.sink { received.append($0) }
    action()
    cancellable.cancel()
    return received
}

/// Runs `action` concurrently across `workers` threads, each
/// performing `iterations` calls. Waits up to 5 seconds for all
/// workers to finish and returns whether they completed in time.
@discardableResult
func performConcurrently(
    workers: Int = 4,
    iterations: Int = 100,
    action: @escaping @Sendable (Int) -> Void,
    onWorkerCompletion: @escaping @Sendable () -> Void = {}
) -> DispatchTimeoutResult {
    let group = DispatchGroup()
    for i in 0 ..< workers {
        group.enter()
        DispatchQueue.global().async {
            for j in 0 ..< iterations {
                action(i * iterations + j)
            }
            onWorkerCompletion()
            group.leave()
        }
    }
    return group.wait(timeout: .now() + 5)
}
