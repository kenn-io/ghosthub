import Foundation
import GhosttyKit
import Testing
@testable import GhosthubTerminal
@testable import GhosthubTerminalSupport

@MainActor
struct LibghosttySurfaceRuntimeCallbacksTests {
    @Test("surface runtime callbacks invoke configured closures")
    func surfaceRuntimeCallbacksInvokeConfiguredClosures() {
        let spy = RuntimeCallbacksSpy()
        let callbacks = spy.callbacks

        callbacks.readClipboard?(.selection, nil)
        callbacks.closeSurface?(true)

        #expect(spy.recordedClipboardLocation == .selection)
        #expect(spy.recordedCloseProcessAlive == true)
    }
}

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

    @Test("open URL action owns its string before main-queue dispatch")
    func openURLActionOwnsStringBeforeDispatch() async throws {
        let configRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: configRoot) }

        var resume: CheckedContinuation<URL, Never>?
        let runtime = LibghosttyRuntime(
            pipeline: LibghosttyConfigPipeline(
                paths: LibghosttyConfigPaths(
                    configDirectory: configRoot
                )
            ),
            configMonitorFactory: { request in
                LibghosttyConfigFileMonitor(
                    fileURLs: request.files,
                    errorHandler: request.errorHandler,
                    changeHandler: request.changeHandler
                )
            },
            urlOpener: { url in
                resume?.resume(returning: url)
                resume = nil
            }
        )
        let app = try #require(runtime.unsafeAppHandle)
        var bytes = Array("https://example.test/pull/81".utf8CString)

        let openedURL = await withCheckedContinuation { continuation in
            resume = continuation
            bytes.withUnsafeMutableBufferPointer { buffer in
                var actionValue = ghostty_action_u()
                actionValue.open_url = ghostty_action_open_url_s(
                    kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT,
                    url: buffer.baseAddress,
                    len: UInt(buffer.count - 1)
                )
                let action = ghostty_action_s(
                    tag: GHOSTTY_ACTION_OPEN_URL,
                    action: actionValue
                )
                let handled = LibghosttyRuntime.handleAction(
                    app: app,
                    target: ghostty_target_s(),
                    action: action
                )
                #expect(handled)

                for index in buffer.indices {
                    buffer[index] = index == buffer.indices.last ? 0 : 120
                }
            }
        }

        #expect(openedURL.absoluteString == "https://example.test/pull/81")
    }
}
