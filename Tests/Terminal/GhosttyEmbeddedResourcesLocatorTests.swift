import Foundation
import Testing
@testable import GhosthubTerminalSupport

struct GhosttyEmbeddedResourcesLocatorTests {
    private func assertResolvesToLayoutResources(
        executablePath: (MockLibghosttyLayout) -> String,
        currentDirectoryPath: (MockLibghosttyLayout) -> String
    ) throws {
        let layout = try MockLibghosttyLayout.create()

        let resolved =
            GhosttyEmbeddedResourcesLocator.resolveResourcesDirectory(
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
}
