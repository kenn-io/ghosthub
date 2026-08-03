// swift-tools-version: 6.2

import Foundation
import PackageDescription

let fileManager = FileManager.default
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let libghosttyBuildRoot = packageRoot.appendingPathComponent(".build/libghostty", isDirectory: true)
let vendorMetadataPath = packageRoot.appendingPathComponent("Vendor/ghostty.version.json")
let libghosttyManifestPath = libghosttyBuildRoot.appendingPathComponent("manifest.json")
let requiredLibghosttyBootstrapVersion = 21

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
            name: "CGhostty",
            path: ".build/libghostty/GhosttyKit.xcframework"
        )
    )
    targets.append(
        .target(
            name: "GhosthubTerminal",
            dependencies: [
                "GhosthubTerminalSupport",
                "GhosthubWorkspace",
                "CGhostty",
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
        path: "Sources/Tmux"
    )
)

targets.append(
    .executableTarget(
        name: "GhosthubApp",
        dependencies: [
            "GhosthubUI",
            "GhosthubSettings",
            "GhosthubWorkspace",
            "GhosthubTerminal",
            "GhosthubTerminalSupport",
            "GhosthubPersistence",
            "GhosthubTmux",
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
            "GhosthubUI",
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
    terminalTestDependencies.append("CGhostty")
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
        name: "GhosthubTmuxTests",
        dependencies: [
            "GhosthubTmux",
        ],
        path: "Tests/Tmux"
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
        .macOS(.v26),
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
