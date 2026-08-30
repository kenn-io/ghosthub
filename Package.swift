// swift-tools-version: 6.2

import Foundation
import PackageDescription

let fileManager = FileManager.default
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let libghosttyBuildRoot = packageRoot.appendingPathComponent(".build/libghostty", isDirectory: true)
let vendorMetadataPath = packageRoot.appendingPathComponent("Vendor/ghostty.version.json")
let libghosttyManifestPath = libghosttyBuildRoot.appendingPathComponent("manifest.json")
/// Increment whenever Ghosthub's libghostty patch surface changes.
let requiredLibghosttyBootstrapVersion = 24

func loadJSONDictionary(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }

    return object
}

let hasBootstrappedLibghostty: Bool = {
    guard ProcessInfo.processInfo.environment[
        "GHOSTHUB_FORCE_TERMINAL_UNAVAILABLE"
    ] != "1" else {
        return false
    }
    let xcframeworkPath = libghosttyBuildRoot.appendingPathComponent("GhosttyKit.xcframework").path
    guard fileManager.fileExists(atPath: xcframeworkPath) else {
        return false
    }

    guard let vendorMetadata = loadJSONDictionary(at: vendorMetadataPath),
          let manifest = loadJSONDictionary(at: libghosttyManifestPath),
          let vendorCommit = vendorMetadata["commit"] as? String,
          let builtCommit = manifest["ghosttyCommit"] as? String,
          let bootstrapVersion = manifest["ghosthubBootstrapVersion"] as? Int
    else {
        return false
    }

    return vendorCommit == builtCommit && bootstrapVersion == requiredLibghosttyBootstrapVersion
}()

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
        name: "GhosthubZellij",
        dependencies: [
            "GhosthubTransport",
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
        path: "Sources/UI",
        resources: [
            .process("Resources"),
        ]
    ),
    .target(
        name: "GhosthubTerminalSupport",
        path: "Sources/TerminalSupport"
    ),
]

if hasBootstrappedLibghostty {
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
} else {
    targets.append(
        .target(
            name: "GhosthubTerminal",
            dependencies: [
                "GhosthubTerminalSupport",
                "GhosthubWorkspace",
            ],
            path: "Sources/TerminalUnavailable"
        )
    )
}

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
var terminalTestDependencies: [Target.Dependency] = [
    "GhosthubTerminal",
    "GhosthubTerminalSupport",
    "GhosthubWorkspace",
    "GhosthubTestSupport",
]
if hasBootstrappedLibghostty {
    // AttachedTmuxInputTests imports the XCFramework's Clang module directly.
    terminalTestDependencies.append("GhosttyKit")
}
targets.append(
    .testTarget(
        name: "GhosthubTerminalTests",
        dependencies: terminalTestDependencies,
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
if hasBootstrappedLibghostty {
    targets.append(
        .testTarget(
            name: "GhosthubTerminalSmokeTests",
            dependencies: [
                "GhosthubApp",
                "GhosthubTerminal",
                "GhosthubTerminalSupport",
                "GhosthubTestSupport",
                "GhosthubTransport",
                "GhosthubTmux",
                "GhosthubUI",
                "GhosthubWorkspace",
            ],
            path: "Tests/TerminalSmoke"
        )
    )
}

let package = Package(
    name: "Ghosthub",
    platforms: [
        .macOS(.v15),
    ],
    products: products,
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            exact: "2.9.4"
        ),
    ],
    targets: targets
)
