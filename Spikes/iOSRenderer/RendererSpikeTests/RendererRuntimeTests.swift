import Foundation
import Testing
@testable import RendererSpike

@Suite("Renderer runtime")
@MainActor
struct RendererRuntimeTests {
    @Test("live runtime initializes and shuts down idempotently")
    func liveRuntimeLifecycle() {
        let runtime = RendererRuntime()

        #expect(runtime.status == .idle)
        runtime.start()
        #expect(runtime.status == .appReady)

        runtime.shutdown()
        #expect(runtime.status == .idle)
        runtime.shutdown()
        #expect(runtime.status == .idle)
    }

    @Test("missing resources identify the library initialization stage")
    func missingResources() {
        let runtime = RendererRuntime()
        let missingRoot = URL(fileURLWithPath: "/renderer-spike-missing-resources")

        runtime.start(resourceRoot: missingRoot)

        guard case let .failed(stage, message) = runtime.status else {
            Issue.record("Expected stage-specific resource failure")
            return
        }
        #expect(stage == .libraryReady)
        #expect(!message.isEmpty)
    }
}
