import Foundation

private let requiredLauncherEnvironmentNames = [
    "PATH",
    "HOME",
    "TMPDIR",
    "CFFIXED_USER_HOME",
    "DEVELOPER_DIR",
    "GHOSTHUB_CI_STATE_ROOT",
    "LIBGHOSTTY_XCFRAMEWORK_TARGET",
    "LIBGHOSTTY_ZIG",
    "RUNNER_TEMP",
    "SHELL",
    "TMUX_TMPDIR",
    "GHOSTHUB_TEST_TMUX_RUN_ID",
    "GHOSTTY_RESOURCES_DIR",
]

private let optionalLauncherEnvironmentNames = [
    "RUNNER_ENVIRONMENT",
    "CI",
    "GITHUB_ACTIONS",
]

struct LauncherEnvironmentError: Error, CustomStringConvertible {
    let name: String

    var description: String {
        "GUI launcher environment is missing \(name)."
    }
}

func makeLauncherEnvironment(
    controllerEnvironment: [String: String],
    workspacePath: String
) throws -> [String: String] {
    var environment: [String: String] = [:]
    for name in requiredLauncherEnvironmentNames {
        guard let value = controllerEnvironment[name], !value.isEmpty else {
            throw LauncherEnvironmentError(name: name)
        }
        environment[name] = value
    }
    for name in optionalLauncherEnvironmentNames {
        environment[name] = controllerEnvironment[name] ?? ""
    }

    let developerDirectory = URL(
        fileURLWithPath: environment["DEVELOPER_DIR"]!,
        isDirectory: true
    )
    let platformDeveloperDirectory = developerDirectory
        .appendingPathComponent("Platforms/MacOSX.platform/Developer", isDirectory: true)
    environment["DYLD_LIBRARY_PATH"] = platformDeveloperDirectory
        .appendingPathComponent("usr/lib", isDirectory: true)
        .path
    environment["DYLD_FRAMEWORK_PATH"] = [
        platformDeveloperDirectory
            .appendingPathComponent("Library/Frameworks", isDirectory: true)
            .path,
        platformDeveloperDirectory
            .appendingPathComponent("Library/PrivateFrameworks", isDirectory: true)
            .path,
    ].joined(separator: ":")
    environment["PWD"] = workspacePath
    environment["GITHUB_WORKSPACE"] = workspacePath
    return environment
}
