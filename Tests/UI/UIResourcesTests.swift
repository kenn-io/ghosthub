import Foundation
@testable import GhosthubUI
import Testing

@Suite("Packaged UI resources")
struct UIResourcesTests {
    @Test("loads resources from a sealable app bundle location")
    func loadsPackagedResource() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let applicationURL = temporaryDirectory
            .appendingPathComponent("Ghosthub.app", isDirectory: true)
        let resourceBundleURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(
                "Ghosthub_GhosthubUI.bundle",
                isDirectory: true
            )
        let resourceURL = resourceBundleURL
            .appendingPathComponent("probe.txt", isDirectory: false)

        try FileManager.default.createDirectory(
            at: resourceBundleURL,
            withIntermediateDirectories: true
        )
        try "packaged resource".write(
            to: resourceURL,
            atomically: true,
            encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let bundle = try #require(
            UIResources.packagedBundle(
                applicationBundleURL: applicationURL
            )
        )
        let loadedURL = try #require(
            bundle.url(forResource: "probe", withExtension: "txt")
        )

        #expect(
            try String(contentsOf: loadedURL, encoding: .utf8)
                == "packaged resource"
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: applicationURL,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent) == ["Contents"]
        )
    }

    @Test("does not reinterpret development directories as app bundles")
    func rejectsNonApplicationBundle() {
        #expect(
            UIResources.packagedBundle(
                applicationBundleURL: URL(fileURLWithPath: "/tmp/Ghosthub")
            ) == nil
        )
    }
}
