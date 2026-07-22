import Foundation

/// Thread-safe tracker that records render timestamps per surface.
///
/// Called from ghostty's render thread (not main thread), so
/// synchronization uses NSLock rather than main-actor dispatch.
public final class SurfaceRenderTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UInt: Date] = [:]

    public init() {}

    /// Record that a surface produced render output.
    /// Safe to call from any thread.
    public func recordRender(surfaceIdentity: UInt) {
        let now = Date()
        lock.lock()
        entries[surfaceIdentity] = now
        lock.unlock()
    }

    /// Drain all recorded entries and return them.
    /// Returns the accumulated entries since the last drain, then clears
    /// the internal buffer. Safe to call from any thread.
    public func drain() -> [UInt: Date] {
        lock.lock()
        let snapshot = entries
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
        return snapshot
    }
}
