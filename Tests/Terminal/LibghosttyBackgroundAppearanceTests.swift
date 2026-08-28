import Foundation
import GhosttyKit
import Testing
@testable import GhosthubTerminal
@testable import GhosthubTerminalSupport

@MainActor
@Suite("Libghostty background appearance")
struct LibghosttyBackgroundAppearanceTests {
    private func loadConfig(_ contents: String) throws -> ghostty_config_t {
        try #require(LibghosttyRuntime.ensureLibraryInitialized())
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        // Config loading is eager, so the directory can go as soon as the
        // finalized handle is returned.
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ghostty.conf")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        let config = try #require(ghostty_config_new())
        file.path.withCString { pointer in
            ghostty_config_load_file(config, pointer, file.path.utf8.count)
        }
        ghostty_config_finalize(config)
        return config
    }

    @Test("reads opacity and blur from config")
    func readsTransparentConfig() throws {
        let config = try loadConfig(
            """
            background-opacity = 0.8
            background-blur = true
            """
        )
        defer { ghostty_config_free(config) }
        let appearance = LibghosttyRuntime.readBackgroundAppearance(
            from: config, increasedContrast: false
        )
        #expect(appearance.opacity == 0.8)
        #expect(appearance.blur == .radius(20))
        #expect(appearance.isTransparent)
    }

    @Test("defaults to opaque when keys are absent")
    func defaultsOpaque() throws {
        let config = try loadConfig("font-size = 13\n")
        defer { ghostty_config_free(config) }
        let appearance = LibghosttyRuntime.readBackgroundAppearance(
            from: config, increasedContrast: false
        )
        #expect(appearance == .opaque)
    }

    @Test("numeric blur radius is preserved")
    func numericBlur() throws {
        let config = try loadConfig(
            """
            background-opacity = 0.9
            background-blur = 32
            """
        )
        defer { ghostty_config_free(config) }
        let appearance = LibghosttyRuntime.readBackgroundAppearance(
            from: config, increasedContrast: false
        )
        #expect(appearance.blur == .radius(32))
    }

    @Test("publishes appearance at startup and on reload")
    func publishesAppearanceAcrossReloads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let pipeline = LibghosttyConfigPipeline(
            paths: LibghosttyConfigPaths(configDirectory: dir)
        )
        try "background-opacity = 0.8\n".write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )

        // A no-op change handler keeps filesystem events from triggering
        // reloads mid-test; the explicit reloadConfig below is synchronous.
        // Contrast is pinned off so the 0.8 -> 1.0 transition is always
        // observable regardless of this machine's accessibility settings.
        let runtime = LibghosttyRuntime(
            pipeline: pipeline,
            configMonitorFactory: { request in
                LibghosttyConfigFileMonitor(
                    fileURLs: request.files,
                    errorHandler: request.errorHandler,
                    changeHandler: {}
                )
            },
            increasedContrastProvider: { false }
        )
        try #require(runtime.phase == .ready)

        #expect(runtime.backgroundAppearance.opacity == 0.8)
        #expect(runtime.backgroundAppearance.isTransparent)

        try "background-opacity = 1.0\n".write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )
        runtime.reloadConfig(force: true)

        #expect(runtime.backgroundAppearance == .opaque)
    }

    @Test("increased contrast forces opaque")
    func increasedContrastForcesOpaque() throws {
        let config = try loadConfig(
            """
            background-opacity = 0.8
            background-blur = true
            """
        )
        defer { ghostty_config_free(config) }
        let appearance = LibghosttyRuntime.readBackgroundAppearance(
            from: config, increasedContrast: true
        )
        #expect(appearance == .opaque)
    }
}
