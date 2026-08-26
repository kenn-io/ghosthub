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
