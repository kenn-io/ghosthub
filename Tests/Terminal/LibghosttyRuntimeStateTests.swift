import Foundation
import Testing
@testable import GhosthubTerminal
@testable import GhosthubTerminalSupport

@MainActor
@Suite("Libghostty application actions", .serialized)
struct LibghosttyApplicationActionTests {
    @Test("semantic quit invokes the configured application handler")
    func semanticQuitInvokesConfiguredApplicationHandler() {
        let configRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: configRoot) }
        let runtime = LibghosttyRuntime(
            pipeline: LibghosttyConfigPipeline(
                paths: LibghosttyConfigPaths(
                    configDirectory: configRoot
                )
            )
        )
        var quitRequests = 0
        runtime.quitRequestHandler = {
            quitRequests += 1
        }

        runtime.requestQuit()

        #expect(runtime.runtimeState.lastAction == .quit)
        #expect(quitRequests == 1)
    }
}
