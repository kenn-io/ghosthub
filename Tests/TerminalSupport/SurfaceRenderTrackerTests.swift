import Foundation
import Testing
@testable import GhosthubTerminalSupport

struct SurfaceRenderTrackerTests {
    let tracker = SurfaceRenderTracker()

    @Test("record and drain returns entries")
    func recordAndDrainReturnsEntries() {
        tracker.recordRender(surfaceIdentity: 1)
        tracker.recordRender(surfaceIdentity: 2)

        let entries = tracker.drain()
        #expect(entries.count == 2)
        #expect(entries[1] != nil)
        #expect(entries[2] != nil)
    }

    @Test("a second drain is empty")
    func secondDrainIsEmpty() {
        tracker.recordRender(surfaceIdentity: 42)
        _ = tracker.drain()

        let entries = tracker.drain()
        #expect(entries.isEmpty)
    }

    @Test("drain with no records returns empty")
    func drainWithNoRecordsReturnsEmpty() {
        #expect(tracker.drain().isEmpty)
    }

    @Test("the same identity overwrites with the latest date")
    func sameIdentityOverwritesWithLatestDate() throws {
        tracker.recordRender(surfaceIdentity: 1)
        let firstDate = try #require(tracker.drain()[1])

        tracker.recordRender(surfaceIdentity: 1)
        let secondDate = try #require(tracker.drain()[1])

        #expect(secondDate >= firstDate)
    }

    @Test("concurrent access completes without leaving pending work")
    func concurrentAccessDoesNotCrash() {
        let iterations = 100
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for iteration in 0 ..< iterations {
                let identity = worker * iterations + iteration
                tracker.recordRender(surfaceIdentity: UInt(identity))
                if identity % 25 == 0 {
                    _ = tracker.drain()
                }
            }
            _ = tracker.drain()
        }

        #expect(tracker.drain().isEmpty)
    }
}
