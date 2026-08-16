import Foundation
import Testing
@testable import GhosthubTerminalSupport

struct LibghosttyEmbeddedResourcesLocatorTests {
    private func assertResolvesToLayoutResources(
        share: MockLibghosttyLayout.SharePrefix = .repoLocalBootstrap,
        executablePath: (MockLibghosttyLayout) -> String,
        currentDirectoryPath: (MockLibghosttyLayout) -> String
    ) throws {
        let layout = try MockLibghosttyLayout.create(share: share)

        let resolved =
            LibghosttyEmbeddedResourcesLocator.resolveResourcesDirectory(
                executablePath: executablePath(layout),
                currentDirectoryPath: currentDirectoryPath(layout)
            )

        #expect(resolved == layout.resources)
    }

    @Test("resolveResourcesDirectory finds the repo-local bootstrap layout")
    func resolveResourcesDirectoryFindsRepoLocalBootstrapLayout() throws {
        try assertResolvesToLayoutResources(
            executablePath: { layout in
                layout.root.appendingPathComponent(
                    ".build/arm64-apple-macosx/debug/Ghosthub",
                    isDirectory: false
                ).path
            },
            currentDirectoryPath: { _ in "/tmp" }
        )
    }

    @Test("resolveResourcesDirectory falls back to the current directory")
    func resolveResourcesDirectoryFallsBackToCurrentDirectory() throws {
        try assertResolvesToLayoutResources(
            executablePath: { _ in
                "/Applications/Ghosthub.app/Contents/MacOS/Ghosthub"
            },
            currentDirectoryPath: { $0.root.path }
        )
    }

    @Test("resolveResourcesDirectory finds the packaged app bundle layout")
    func resolveResourcesDirectoryFindsPackagedAppBundleLayout() throws {
        try assertResolvesToLayoutResources(
            share: .packagedAppBundle,
            executablePath: { layout in
                layout.root.appendingPathComponent(
                    "Contents/MacOS/Ghosthub",
                    isDirectory: false
                ).path
            },
            currentDirectoryPath: { _ in "/tmp" }
        )
    }

    @Test("Ghosthub's own resources override an inherited Ghostty.app path")
    func ownResourcesOverrideInheritedGhosttyPath() throws {
        let layout = try MockLibghosttyLayout.create(share: .packagedAppBundle)

        let resolved = LibghosttyEmbeddedResourcesLocator
            .effectiveResourcesDirectory(
                executablePath: layout.root.appendingPathComponent(
                    "Contents/MacOS/Ghosthub",
                    isDirectory: false
                ).path,
                currentDirectoryPath: "/tmp",
                inheritedResourcesPath:
                "/Applications/Ghostty.app/Contents/Resources/ghostty"
            )

        #expect(resolved == layout.resources)
    }

    @Test("an inherited path is used only when Ghosthub ships no resources")
    func inheritedPathIsUsedOnlyWithoutOwnResources() {
        let inherited = "/Applications/Ghostty.app/Contents/Resources/ghostty"

        let resolved = LibghosttyEmbeddedResourcesLocator
            .effectiveResourcesDirectory(
                executablePath: "/Applications/Ghosthub.app/Contents/MacOS/Ghosthub",
                currentDirectoryPath: "/tmp",
                inheritedResourcesPath: inherited
            )

        #expect(resolved == URL(fileURLWithPath: inherited, isDirectory: true))
    }

    @Test("resolveResourcesDirectory ignores a layout without compiled terminfo")
    func resolveResourcesDirectoryIgnoresLayoutWithoutTerminfo() throws {
        let layout = try MockLibghosttyLayout.create(share: .packagedAppBundle)
        try FileManager.default.removeItem(
            at: layout.root.appendingPathComponent(
                "Contents/Resources/terminfo",
                isDirectory: true
            )
        )

        let resolved =
            LibghosttyEmbeddedResourcesLocator.resolveResourcesDirectory(
                executablePath: layout.root
                    .appendingPathComponent(
                        "Contents/MacOS/Ghosthub",
                        isDirectory: false
                    ).path,
                currentDirectoryPath: "/tmp"
            )

        #expect(resolved == nil)
    }

    @Test("candidate roots terminate at the filesystem root")
    func candidateRootsTerminateAtFilesystemRoot() {
        let roots = LibghosttyEmbeddedResourcesLocator.candidateRoots(
            executablePath: "/Ghosthub",
            currentDirectoryPath: "/"
        )

        #expect(roots.map(\.path) == ["/"])
    }
}
