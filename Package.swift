// swift-tools-version: 6.2

import Foundation
import PackageDescription

let fileManager = FileManager.default
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let libghosttyBuildRoot = packageRoot.appendingPathComponent(".build/libghostty", isDirectory: true)
let vendorMetadataPath = packageRoot.appendingPathComponent("Vendor/ghostty.version.json")
let libghosttyManifestPath = libghosttyBuildRoot.appendingPathComponent("manifest.json")
/// Increment whenever Ghosthub's libghostty patch surface changes.
let requiredLibghosttyBootstrapVersion = 29

func loadJSONDictionary(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }

    return object
}

/// Why the built libghostty cannot be used, or nil when it matches the
/// vendored Ghostty revision and Ghosthub's patch surface.
let libghosttyProblem: String? = {
    let xcframeworkPath = libghosttyBuildRoot.appendingPathComponent("GhosttyKit.xcframework").path
    guard fileManager.fileExists(atPath: xcframeworkPath) else {
        return "has not been built"
    }
    guard let vendorMetadata = loadJSONDictionary(at: vendorMetadataPath),
          let manifest = loadJSONDictionary(at: libghosttyManifestPath),
          let vendorCommit = vendorMetadata["commit"] as? String,
          let builtCommit = manifest["ghosttyCommit"] as? String,
          let bootstrapVersion = manifest["ghosthubBootstrapVersion"] as? Int
    else {
        return "has no readable build manifest"
    }
    guard vendorCommit == builtCommit, bootstrapVersion == requiredLibghosttyBootstrapVersion else {
        return "is out of date"
    }
    return nil
}()

if let libghosttyProblem {
    fatalError("libghostty \(libghosttyProblem). Run `make bootstrap-libghostty`.")
}

var products: [Product] = [
    .library(
        name: "GhosthubWorkspace",
        targets: ["GhosthubWorkspace"]
    ),
    .library(
        name: "GhosthubPersistence",
        targets: ["GhosthubPersistence"]
    ),
    .library(
        name: "GhosthubUI",
        targets: ["GhosthubUI"]
    ),
    .library(
        name: "GhosthubSettings",
        targets: ["GhosthubSettings"]
    ),
    .library(
        name: "GhosthubTerminal",
        targets: ["GhosthubTerminal"]
    ),
    .executable(
        name: "Ghosthub",
        targets: ["GhosthubApp"]
    ),
]

var targets: [Target] = [
    .target(
        name: "GhosthubTransport",
        path: "Sources/Transport"
    ),
    .target(
        name: "GhosthubHerdr",
        dependencies: [
            "GhosthubTransport",
            "GhosthubWorkspace",
        ],
        path: "Sources/Herdr"
    ),
    .target(
        name: "GhosthubBackendTerminal",
        dependencies: [
            "GhosthubHerdr",
            "GhosthubTerminalSupport",
            "GhosthubTransport",
            "GhosthubWorkspace",
        ],
        path: "Sources/BackendTerminal"
    ),
    .target(
        name: "GhosthubZellij",
        dependencies: [
            "GhosthubTransport",
            "GhosthubWorkspace",
        ],
        path: "Sources/Zellij"
    ),
    .target(
        name: "GhosthubWorkspace",
        path: "Sources/Workspace"
    ),
    .target(
        name: "GhosthubPersistence",
        dependencies: [
            "GhosthubWorkspace",
            .product(name: "GRDB", package: "GRDB.swift"),
        ],
        path: "Sources/Persistence"
    ),
    .target(
        name: "GhosthubSettings",
        dependencies: [
            "GhosthubWorkspace",
            "GhosthubTerminalSupport",
        ],
        path: "Sources/Settings"
    ),
    .target(
        name: "GhosthubUI",
        dependencies: [
            "GhosthubSettings",
            "GhosthubWorkspace",
            "GhosthubTerminalSupport",
        ],
        path: "Sources/UI"
    ),
    .target(
        name: "GhosthubTerminalSupport",
        path: "Sources/TerminalSupport"
    ),
]

targets.append(
    .binaryTarget(
        name: "GhosttyKit",
        path: ".build/libghostty/GhosttyKit.xcframework"
    )
)
targets.append(
    .target(
        name: "GhosthubTerminal",
        dependencies: [
            "GhosthubTerminalSupport",
            "GhosthubWorkspace",
            "GhosttyKit",
        ],
        path: "Sources/Terminal",
        linkerSettings: [
            .linkedFramework("Carbon"),
        ]
    )
)

targets.append(
    .target(
        name: "GhosthubTmux",
        dependencies: [
            "GhosthubTransport",
        ],
        path: "Sources/Tmux"
    )
)

targets.append(
    .executableTarget(
        name: "GhosthubApp",
        dependencies: [
            "GhosthubBackendTerminal",
            "GhosthubHerdr",
            "GhosthubUI",
            "GhosthubSettings",
            "GhosthubWorkspace",
            "GhosthubTerminal",
            "GhosthubTerminalSupport",
            "GhosthubPersistence",
            "GhosthubTransport",
            "GhosthubTmux",
            "GhosthubZellij",
            .product(name: "Sparkle", package: "Sparkle"),
        ],

        path: "Sources/App",
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-rpath",
                "-Xlinker", "@executable_path/../Frameworks",
            ]),
        ]
    )
)

targets.append(
    .target(
        name: "GhosthubTestSupport",
        dependencies: [
            "GhosthubWorkspace",
            "GhosthubPersistence",
        ],
        path: "Tests/TestSupport"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubSettingsTests",
        dependencies: [
            "GhosthubSettings",
            "GhosthubTerminalSupport",
            "GhosthubWorkspace",
            "GhosthubTestSupport",
        ],
        path: "Tests/Settings"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubWorkspaceTests",
        dependencies: [
            "GhosthubWorkspace",
            "GhosthubTestSupport",
        ],
        path: "Tests/Workspace"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubPersistenceTests",
        dependencies: [
            "GhosthubPersistence",
            "GhosthubWorkspace",
            "GhosthubTestSupport",
        ],
        path: "Tests/Persistence"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubUITests",
        dependencies: [
            "GhosthubUI",
            "GhosthubSettings",
            "GhosthubWorkspace",
            "GhosthubTerminalSupport",
            "GhosthubTestSupport",
        ],
        path: "Tests/UI"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubAppTests",
        dependencies: [
            "GhosthubApp",
            "GhosthubBackendTerminal",
            "GhosthubHerdr",
            "GhosthubTransport",
            "GhosthubUI",
            "GhosthubWorkspace",
            "GhosthubZellij",
            "GhosthubTestSupport",
        ],
        path: "Tests/App"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubTerminalSupportTests",
        dependencies: [
            "GhosthubTerminalSupport",
        ],
        path: "Tests/TerminalSupport"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubTerminalTests",
        dependencies: [
            "GhosthubTerminal",
            "GhosthubTerminalSupport",
            "GhosthubWorkspace",
            "GhosthubTestSupport",
            // AttachedTmuxInputTests imports the XCFramework's Clang module directly.
            "GhosttyKit",
        ],
        path: "Tests/Terminal"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubHerdrTests",
        dependencies: [
            "GhosthubHerdr",
            "GhosthubTransport",
            "GhosthubWorkspace",
        ],
        path: "Tests/Herdr"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubBackendTerminalTests",
        dependencies: [
            "GhosthubBackendTerminal",
            "GhosthubTerminalSupport",
            "GhosthubTransport",
            "GhosthubWorkspace",
        ],
        path: "Tests/BackendTerminal"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubTransportTests",
        dependencies: [
            "GhosthubTransport",
        ],
        path: "Tests/Transport"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubTmuxTests",
        dependencies: [
            "GhosthubTransport",
            "GhosthubTmux",
            "GhosthubTestSupport",
        ],
        path: "Tests/Tmux"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubZellijTests",
        dependencies: [
            "GhosthubTransport",
            "GhosthubZellij",
        ],
        path: "Tests/Zellij"
    )
)
targets.append(
    .testTarget(
        name: "GhosthubTerminalSmokeTests",
        dependencies: [
            "GhosthubApp",
            "GhosthubBackendTerminal",
            "GhosthubHerdr",
            "GhosthubTerminal",
            "GhosthubTerminalSupport",
            "GhosthubTestSupport",
            "GhosthubTransport",
            "GhosthubTmux",
            "GhosthubUI",
            "GhosthubWorkspace",
            "GhosthubZellij",
        ],
        path: "Tests/TerminalSmoke"
    )
)

let package = Package(
    name: "Ghosthub",
    platforms: [
        .macOS(.v15),
    ],
    products: products,
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            exact: "2.10.0"
        ),
    ],
    targets: targets
)
