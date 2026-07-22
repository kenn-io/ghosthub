import Foundation
import GhosthubTestSupport
import Testing
@testable import GhosthubWorkspace

final class ConfigHomeTests {
    private let tempRoot: URL
    private let defaultDir: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaultDir = tempRoot
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ghosthub", isDirectory: true)
        try FileManager.default.createDirectory(
            at: defaultDir,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private var defaultExpectedConfigHome: URL {
        ExpectedPaths.configHome
    }

    private func writeInitToml(_ content: String) throws {
        try content.write(
            to: defaultDir.appendingPathComponent("init.toml"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeTargetDir(_ name: String) -> URL {
        tempRoot.appendingPathComponent(name, isDirectory: true)
    }

    private func resolveConfig(
        env: [String: String] = [:]
    ) -> URL {
        ConfigHome.resolved(environment: env, fileManager: .default)
    }

    private func readInitToml() -> URL? {
        ConfigHome.readInitToml(
            in: defaultDir,
            fileManager: .default
        )
    }

    @Test("default config home falls back to ~/.config/ghosthub")
    func defaultFallback() {
        let result = resolveConfig()
        #expect(result == defaultExpectedConfigHome)
    }

    @Test("environment variable overrides the default config home")
    func environmentVariableOverride() {
        let customPath = makeTargetDir("custom-config")
        let result = resolveConfig(
            env: ["GHOSTHUB_CONFIG_HOME": customPath.path]
        )
        #expect(result == customPath)
    }

    @Test("init.toml can override the config home")
    func initTomlOverride() throws {
        let targetDir = makeTargetDir("synced-config")
        try writeInitToml("config_home = \"\(targetDir.path)\"")
        let result = readInitToml()
        #expect(result == targetDir)
    }

    @Test("environment takes precedence over init.toml")
    func environmentTakesPrecedenceOverInitToml() throws {
        let initTarget = makeTargetDir("from-init")
        let envTarget = makeTargetDir("from-env")
        try writeInitToml("config_home = \"\(initTarget.path)\"")
        let result = resolveConfig(
            env: ["GHOSTHUB_CONFIG_HOME": envTarget.path]
        )
        #expect(result == envTarget)
    }

    @Test("invalid init.toml is ignored")
    func invalidInitTomlIgnored() throws {
        try writeInitToml("this is not valid toml key-value content")
        let result = readInitToml()
        #expect(result == nil)
    }

    @Test("init.toml parsing tolerates comments")
    func initTomlWithComments() throws {
        let targetDir = makeTargetDir("synced")
        try writeInitToml("""
        # Redirect to synced config
        config_home = "\(targetDir.path)"
        """)
        let result = readInitToml()
        #expect(result == targetDir)
    }

    @Test("empty environment variables are ignored")
    func emptyEnvironmentVariableIgnored() {
        let result = resolveConfig(
            env: ["GHOSTHUB_CONFIG_HOME": ""]
        )
        #expect(result == defaultExpectedConfigHome)
    }

    @Test("parseConfigHome accepts unquoted absolute values")
    func parseConfigHomeUnquotedValue() {
        let result = ConfigHome.parseConfigHome(
            from: "config_home = /tmp/ghosthub-config"
        )
        #expect(
            result
                == URL(
                    fileURLWithPath: "/tmp/ghosthub-config",
                    isDirectory: true
                )
        )
    }

    @Test("relative environment values fall back to the default config home")
    func relativeEnvPathFallsBackToDefault() {
        let result = resolveConfig(
            env: ["GHOSTHUB_CONFIG_HOME": "relative/path"]
        )
        #expect(result == defaultExpectedConfigHome)
    }

    @Test("relative init.toml values are ignored")
    func relativeInitTomlPathIgnored() {
        let result = ConfigHome.parseConfigHome(
            from: "config_home = relative/config"
        )
        #expect(result == nil)
    }
}

struct ConfigHomeGhosthubHomeTests {
    @Test("GHOSTHUB_HOME derives config subdirectory")
    func resolvesFromGhosthubHome() {
        let env = ["GHOSTHUB_HOME": "/custom/home"]
        let url = ConfigHome.resolved(environment: env)
        #expect(url.path == "/custom/home/config")
    }

    @Test("GHOSTHUB_CONFIG_HOME takes precedence over GHOSTHUB_HOME")
    func ghosthubConfigHomeOverridesGhosthubHome() {
        let env = [
            "GHOSTHUB_CONFIG_HOME": "/specific/config",
            "GHOSTHUB_HOME": "/general",
        ]
        let url = ConfigHome.resolved(environment: env)
        #expect(url.path == "/specific/config")
    }

    @Test("empty GHOSTHUB_HOME is ignored")
    func emptyGhosthubHomeIgnored() {
        let url = ConfigHome.resolved(
            environment: ["GHOSTHUB_HOME": ""]
        )
        #expect(url == ExpectedPaths.configHome)
    }
}

struct StateHomeTests {
    @Test("resolved defaults to ~/.ghosthub")
    func resolvedDefaultsToDotGhosthubInHomeDirectory() {
        #expect(StateHome.resolved() == ExpectedPaths.stateHome)
    }

    @Test("default worktrees directory lives under the state home")
    func defaultWorktreesDirectoryLivesUnderStateHome() {
        #expect(
            StateHome.defaultWorktreesDirectory()
                == ExpectedPaths.worktrees
        )
    }

    @Test("GHOSTHUB_STATE_HOME overrides the default")
    func resolvesFromGhosthubStateHome() {
        let env = ["GHOSTHUB_STATE_HOME": "/custom/state"]
        let url = StateHome.resolved(environment: env)
        #expect(url.path == "/custom/state")
    }

    @Test("GHOSTHUB_HOME derives state subdirectory")
    func resolvesFromGhosthubHome() {
        let env = ["GHOSTHUB_HOME": "/custom/home"]
        let url = StateHome.resolved(environment: env)
        #expect(url.path == "/custom/home/state")
    }

    @Test("GHOSTHUB_STATE_HOME takes precedence over GHOSTHUB_HOME")
    func ghosthubStateHomeOverridesGhosthubHome() {
        let env = [
            "GHOSTHUB_STATE_HOME": "/specific",
            "GHOSTHUB_HOME": "/general",
        ]
        let url = StateHome.resolved(environment: env)
        #expect(url.path == "/specific")
    }

    @Test("empty environment falls back to ~/.ghosthub")
    func defaultsToHomeDotGhosthub() {
        let url = StateHome.resolved(environment: [:])
        #expect(url.path.hasSuffix(".ghosthub"))
    }

    @Test("empty GHOSTHUB_STATE_HOME is ignored")
    func emptyStateHomeIgnored() {
        let url = StateHome.resolved(
            environment: ["GHOSTHUB_STATE_HOME": ""]
        )
        #expect(url.path.hasSuffix(".ghosthub"))
    }

    @Test("empty GHOSTHUB_HOME is ignored")
    func emptyGhosthubHomeIgnored() {
        let url = StateHome.resolved(
            environment: ["GHOSTHUB_HOME": ""]
        )
        #expect(url.path.hasSuffix(".ghosthub"))
    }

    @Test("defaultWorktreesDirectory respects GHOSTHUB_STATE_HOME")
    func worktreesDirectoryRespectsStateHome() {
        let env = ["GHOSTHUB_STATE_HOME": "/custom/state"]
        let url = StateHome.defaultWorktreesDirectory(
            environment: env
        )
        #expect(url.path == "/custom/state/worktrees")
    }

    @Test("defaultWorktreesDirectory respects GHOSTHUB_HOME")
    func worktreesDirectoryRespectsGhosthubHome() {
        let env = ["GHOSTHUB_HOME": "/custom/home"]
        let url = StateHome.defaultWorktreesDirectory(
            environment: env
        )
        #expect(url.path == "/custom/home/state/worktrees")
    }
}
