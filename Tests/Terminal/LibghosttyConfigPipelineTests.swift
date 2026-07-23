import Foundation
import GhosthubTestSupport
import Testing
@testable import GhosthubTerminalSupport

struct LibghosttyConfigPipelineTests {
    @Test("loadPlan creates the default global config when it is missing")
    func loadPlanCreatesDefaultGlobalConfigWhenMissing() throws {
        let fixture = try ConfigPipelineFixture.create(createConfigDirectory: false)

        let plan = try fixture.pipeline.loadPlan()

        #expect(plan.createdGlobalConfig)
        #expect(plan.globalConfigFile == fixture.paths.globalConfigFile)
        #expect(plan.projectConfigFile == nil)
        #expect(plan.orderedConfigFiles == [fixture.paths.globalConfigFile])
        #expect(
            plan.watchedConfigFiles == [
                fixture.paths.globalConfigFile,
                fixture.paths.terminalAppearanceConfigFile,
            ]
        )
        #expect(FileManager.default.fileExists(
            atPath: fixture.paths.globalConfigFile.path
        ))

        let contents = try fixture.readGlobalConfig()
        expectConfig(contents, contains: [
            "font-family = Berkeley Mono",
            "scrollback-limit = 50000000",
            "term = xterm-256color",
            "cursor-style = block",
            "copy-on-select = clipboard",
            "macos-option-as-alt = true",
            "shell-integration = detect",
        ], omits: [
            "shell-integration-features",
        ])
    }

    @Test("loadPlan watches recursive and absent optional config files")
    func loadPlanWatchesCompleteConfigGraph() throws {
        let fixture = try ConfigPipelineFixture.create()
        let nestedDirectory = fixture.paths.configDirectory
            .appendingPathComponent("nested", isDirectory: true)
        let nestedConfig = nestedDirectory
            .appendingPathComponent("base.conf")
        let optionalConfig = nestedDirectory
            .appendingPathComponent("machine.conf")
        let literalQuestionConfig = nestedDirectory
            .appendingPathComponent("?literal.conf")

        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: true
        )
        try """
        config-file = ?machine.conf
        config-file = "?literal.conf"
        font-size = 14
        """.write(
            to: nestedConfig,
            atomically: true,
            encoding: .utf8
        )
        try fixture.writeGlobalConfig(
            """
            config-file = nested/base.conf
            font-family = Berkeley Mono
            """
        )

        let plan = try fixture.pipeline.loadPlan()

        #expect(plan.watchedConfigFiles == [
            fixture.paths.globalConfigFile,
            nestedConfig,
            optionalConfig,
            literalQuestionConfig,
            fixture.paths.terminalAppearanceConfigFile,
        ])
    }

    @Test("loadPlan watches a project override before it exists")
    func loadPlanWatchesAbsentProjectOverride() throws {
        let fixture = try ConfigPipelineFixture.create()
        let projectRoot = fixture.tempRoot
            .appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )
        let candidate = fixture.paths.projectConfigFile(
            for: projectRoot
        )

        let plan = try fixture.pipeline.loadPlan(
            projectRoot: projectRoot
        )

        #expect(plan.projectConfigFile == nil)
        #expect(plan.watchedConfigFiles.contains(candidate))
    }

    @Test("loadPlan bounds recursive includes through symlink aliases")
    func loadPlanBoundsSymlinkIncludeCycles() throws {
        let fixture = try ConfigPipelineFixture.create()
        let loop = fixture.paths.configDirectory
            .appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(
            at: loop,
            withDestinationURL: fixture.paths.configDirectory
        )
        try fixture.writeGlobalConfig(
            "config-file = loop/ghostty.conf\n"
        )

        let plan = try fixture.pipeline.loadPlan()

        #expect(plan.watchedConfigFiles == [
            fixture.paths.globalConfigFile,
            loop.appendingPathComponent("ghostty.conf"),
            fixture.paths.terminalAppearanceConfigFile,
        ])
    }

    @Test("loadPlan includes a project override when present")
    func loadPlanIncludesProjectOverrideWhenPresent() throws {
        let fixture = try ConfigPipelineFixture.create()

        let (projectRoot, projectConfig) = try fixture.writeProjectConfig(
            content: "font-size = 15\n"
        )

        let plan = try fixture.pipeline.loadPlan(projectRoot: projectRoot)

        #expect(plan.projectConfigFile == projectConfig)
        #expect(
            plan.orderedConfigFiles
                == [fixture.paths.globalConfigFile, projectConfig]
        )
    }

    @Test("loadPlan includes the Ghosthub appearance overlay last when present")
    func loadPlanIncludesAppearanceOverlayLastWhenPresent() throws {
        let fixture = try ConfigPipelineFixture.create()

        let (projectRoot, projectConfig) = try fixture.writeProjectConfig(
            content: "font-size = 15\n"
        )
        try fixture.writeAppearanceConfig("background = #000000\n")

        let plan = try fixture.pipeline.loadPlan(projectRoot: projectRoot)

        #expect(plan.projectConfigFile == projectConfig)
        #expect(
            plan.terminalAppearanceConfigFile
                == fixture.paths.terminalAppearanceConfigFile
        )
        #expect(
            plan.orderedConfigFiles == [
                fixture.paths.globalConfigFile,
                projectConfig,
                fixture.paths.terminalAppearanceConfigFile,
            ]
        )
    }

    @Test("loadPlan backfills managed defaults into an existing config")
    func loadPlanBackfillsManagedDefaultsWhenMissingFromExistingConfig() throws {
        let fixture = try ConfigPipelineFixture.create()

        try fixture.writeGlobalConfig("""
        font-family = Berkeley Mono
        cursor-style = block
        """)

        let plan = try fixture.pipeline.loadPlan()
        #expect(!plan.createdGlobalConfig)

        let contents = try fixture.readGlobalConfig()
        expectConfig(contents, contains: [
            "scrollback-limit = 50000000",
            "term = xterm-256color",
            "macos-option-as-alt = true",
            "shell-integration = detect",
        ], omits: [
            "shell-integration-features",
        ])
    }

    @Test("loadPlan preserves existing scrollback-limit in Ghosthub-generated config")
    func loadPlanPreservesScrollbackInGeneratedConfig() throws {
        let fixture = try ConfigPipelineFixture.create()

        try fixture.writeGlobalConfig("""
        # ~/.config/ghosthub/ghostty.conf
        # Terminal configuration for Ghosthub (standard Ghostty config format)
        font-family = Berkeley Mono
        scrollback-limit = 50000
        term = xterm-256color
        macos-option-as-alt = true
        shell-integration = detect
        """)

        _ = try fixture.pipeline.loadPlan()

        let contents = try fixture.readGlobalConfig()
        expectConfig(
            contents,
            contains: ["scrollback-limit = 50000"],
            omits: ["scrollback-limit = 50000000"]
        )
    }

    @Test("loadPlan preserves user-authored scrollback-limit")
    func loadPlanPreservesUserScrollbackLimit() throws {
        let fixture = try ConfigPipelineFixture.create()

        try fixture.writeGlobalConfig("""
        font-family = JetBrains Mono
        scrollback-limit = 50000
        """)

        _ = try fixture.pipeline.loadPlan()

        let contents = try fixture.readGlobalConfig()
        expectConfig(
            contents,
            contains: ["scrollback-limit = 50000"],
            omits: ["scrollback-limit = 50000000"]
        )
    }

    @Test("loadPlan preserves user-authored shell integration none")
    func loadPlanPreservesUserShellIntegrationNone() throws {
        let fixture = try ConfigPipelineFixture.create()

        try fixture.writeGlobalConfig("""
        font-family = Berkeley Mono
        shell-integration = none
        """)

        _ = try fixture.pipeline.loadPlan()

        let contents = try fixture.readGlobalConfig()
        expectConfig(
            contents,
            contains: ["shell-integration = none"],
            omits: ["shell-integration = detect"]
        )
    }

    @Test("loadPlan preserves user-authored shell integration features")
    func loadPlanPreservesUserShellIntegrationFeaturesNoCursor() throws {
        let fixture = try ConfigPipelineFixture.create()

        try fixture.writeGlobalConfig("""
        font-family = Berkeley Mono
        shell-integration = detect
        shell-integration-features = no-cursor
        term = xterm-256color
        macos-option-as-alt = true
        """)

        _ = try fixture.pipeline.loadPlan()

        let contents = try fixture.readGlobalConfig()
        #expect(
            contents.contains("shell-integration-features = no-cursor")
        )
    }

    @Test("backfill recognizes compact key-value format")
    func backfillRecognizesCompactKeyValueFormat() throws {
        let fixture = try ConfigPipelineFixture.create()

        try fixture.writeGlobalConfig("""
        term=xterm-256color
        macos-option-as-alt=false
        shell-integration= detect
        """)

        _ = try fixture.pipeline.loadPlan()

        let contents = try fixture.readGlobalConfig()
        let termLines = contents
            .split(whereSeparator: \.isNewline)
            .filter { line in
                let trimmed = line.trimmingCharacters(
                    in: .whitespaces
                )
                return trimmed.hasPrefix("term=")
                    || trimmed.hasPrefix("term =")
            }

        #expect(termLines.count == 1)
        expectConfig(
            contents,
            contains: ["macos-option-as-alt=false"],
            omits: ["macos-option-as-alt = true"]
        )
    }

    @Test(
        "init.toml redirect parsing",
        arguments: [
            (
                content: "config_home = ../other-config\n",
                shouldResolve: false
            ),
            (
                content: "config_home = \n",
                shouldResolve: false
            ),
        ]
    )
    func initTomlRedirectRejectsInvalidValues(
        content: String,
        shouldResolve: Bool
    ) throws {
        let fixture = try ConfigPipelineFixture.create()

        try fixture.writeInitToml(content)

        let result = LibghosttyConfigPaths.resolveInitTomlRedirect(
            in: fixture.paths.configDirectory
        )

        #expect((result != nil) == shouldResolve)
    }

    @Test("init.toml redirect accepts an absolute path")
    func initTomlRedirectAcceptsAbsolutePath() throws {
        let fixture = try ConfigPipelineFixture.create()

        let redirectDir = fixture.tempRoot.appendingPathComponent(
            "custom-config",
            isDirectory: true
        )
        try fixture.writeInitToml(
            "config_home = \(redirectDir.path)\n"
        )

        let result = LibghosttyConfigPaths.resolveInitTomlRedirect(
            in: fixture.paths.configDirectory
        )

        #expect(result == redirectDir)
    }
}

private extension LibghosttyConfigPipelineTests {
    struct ConfigPipelineFixture {
        let tempRoot: URL
        let paths: LibghosttyConfigPaths
        let pipeline: LibghosttyConfigPipeline
        let tempDir: TempDirectoryFixture

        static func create(createConfigDirectory: Bool = true) throws -> ConfigPipelineFixture {
            let tempDir = try TempDirectoryFixture()
            let configDirectory = tempDir.url
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("ghosthub", isDirectory: true)

            if createConfigDirectory {
                try FileManager.default.createDirectory(
                    at: configDirectory,
                    withIntermediateDirectories: true
                )
            }

            let paths = LibghosttyConfigPaths(configDirectory: configDirectory)

            return ConfigPipelineFixture(
                tempRoot: tempDir.url,
                paths: paths,
                pipeline: LibghosttyConfigPipeline(paths: paths),
                tempDir: tempDir
            )
        }

        func writeGlobalConfig(_ content: String) throws {
            try content.write(
                to: paths.globalConfigFile,
                atomically: true,
                encoding: .utf8
            )
        }

        func writeInitToml(_ content: String) throws {
            try content.write(
                to: paths.configDirectory
                    .appendingPathComponent("init.toml"),
                atomically: true,
                encoding: .utf8
            )
        }

        @discardableResult
        func writeProjectConfig(
            projectName: String = "project",
            content: String
        ) throws -> (root: URL, configFile: URL) {
            let projectRoot = tempRoot.appendingPathComponent(
                projectName,
                isDirectory: true
            )
            let projectConfig = paths.projectConfigFile(
                for: projectRoot
            )
            try FileManager.default.createDirectory(
                at: projectConfig.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(
                to: projectConfig,
                atomically: true,
                encoding: .utf8
            )
            return (projectRoot, projectConfig)
        }

        func writeAppearanceConfig(_ content: String) throws {
            try content.write(
                to: paths.terminalAppearanceConfigFile,
                atomically: true,
                encoding: .utf8
            )
        }

        func readGlobalConfig() throws -> String {
            try String(
                contentsOf: paths.globalConfigFile,
                encoding: .utf8
            )
        }
    }
}

private func expectConfig(
    _ contents: String,
    contains: [String] = [],
    omits: [String] = []
) {
    for expected in contains where !contents.contains(expected) {
        Issue.record("Expected config to contain '\(expected)'")
    }
    for omitted in omits where contents.contains(omitted) {
        Issue.record("Expected config to omit '\(omitted)'")
    }
}
