import AppKit
import Darwin
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

let launcherAbsentStatus: Int32 = 3

func signalProcessGroup(
    processGroup: pid_t,
    signalNumber: Int32
) -> Int32 {
    if kill(-processGroup, signalNumber) == 0 {
        return 0
    }
    if errno == ESRCH {
        return launcherAbsentStatus
    }
    return 1
}

func signalVerifiedLauncher(
    bundleIdentifier: String,
    applicationURL: URL,
    launcherPID: pid_t,
    signalNumber: Int32
) -> Int32 {
    let application = NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleIdentifier)
        .first { application in
            !application.isTerminated &&
                application.processIdentifier == launcherPID &&
                application.bundleURL?.standardizedFileURL == applicationURL
        }
    guard application != nil else {
        return launcherAbsentStatus
    }
    let processGroup = getpgid(launcherPID)
    if processGroup == -1, errno == ESRCH {
        return launcherAbsentStatus
    }
    guard processGroup == launcherPID else {
        return 1
    }
    return signalProcessGroup(
        processGroup: processGroup,
        signalNumber: signalNumber
    )
}

if CommandLine.arguments.count == 4,
   CommandLine.arguments[1] == "signal-process-group" {
    guard let processGroup = pid_t(CommandLine.arguments[2]),
          processGroup > 0,
          let signalNumber = Int32(CommandLine.arguments[3]),
          [0, SIGINT, SIGTERM, SIGHUP, SIGKILL].contains(signalNumber)
    else {
        fputs(
            "usage: launch-controller signal-process-group process-group signal\n",
            stderr
        )
        exit(2)
    }
    let status = signalProcessGroup(
        processGroup: processGroup,
        signalNumber: signalNumber
    )
    if status == 1 {
        perror("Could not signal GUI launcher process group")
    }
    exit(status)
}

if CommandLine.arguments.count == 6,
   CommandLine.arguments[1] == "signal-launcher" {
    let bundleIdentifier = CommandLine.arguments[2]
    let applicationURL = URL(
        fileURLWithPath: CommandLine.arguments[3]
    ).standardizedFileURL
    guard let launcherPID = pid_t(CommandLine.arguments[4]),
          launcherPID > 0,
          let signalNumber = Int32(CommandLine.arguments[5]),
          [0, SIGINT, SIGTERM, SIGHUP, SIGKILL].contains(signalNumber)
    else {
        fputs(
            "usage: launch-controller signal-launcher " +
                "bundle-id app pid signal\n",
            stderr
        )
        exit(2)
    }
    let status = signalVerifiedLauncher(
        bundleIdentifier: bundleIdentifier,
        applicationURL: applicationURL,
        launcherPID: launcherPID,
        signalNumber: signalNumber
    )
    if status == 1 {
        perror("Could not signal GUI launcher")
    }
    exit(status)
}

final class LaunchState: @unchecked Sendable {
    let queue = DispatchQueue(label: "io.kenn.ghosthub-ci-gui-launch")
    var launchCompleted = false
    var launcherApplication: NSRunningApplication?
    var launcherPID: pid_t?
    var cancellationSignal: Int32?
    var cancellationStatus: Int32?
    var failure: String?
}

guard CommandLine.arguments.count >= 5 else {
    fputs(
        "usage: launch-controller bundle-id app pid-file arguments...\n",
        stderr
    )
    exit(2)
}

let bundleIdentifier = CommandLine.arguments[1]
let applicationURL = URL(
    fileURLWithPath: CommandLine.arguments[2]
).standardizedFileURL
let pidFileURL = URL(fileURLWithPath: CommandLine.arguments[3])
let suppliedArguments = Array(CommandLine.arguments.dropFirst(4))
let launcherArgumentCount = 7
guard suppliedArguments.count == launcherArgumentCount else {
    fputs("GUI launcher arguments are incomplete.\n", stderr)
    exit(2)
}
let applicationArguments = suppliedArguments
let completionFileURL = URL(fileURLWithPath: applicationArguments[6])
let controllerEnvironment = ProcessInfo.processInfo.environment
var launcherEnvironment: [String: String] = [:]
for name in requiredLauncherEnvironmentNames {
    guard let value = controllerEnvironment[name], !value.isEmpty else {
        fputs("GUI launcher environment is missing \(name).\n", stderr)
        exit(2)
    }
    launcherEnvironment[name] = value
}
for name in optionalLauncherEnvironmentNames {
    launcherEnvironment[name] = controllerEnvironment[name] ?? ""
}
let workspacePath = URL(
    fileURLWithPath: applicationArguments[5],
    isDirectory: true
).standardizedFileURL.path
launcherEnvironment["PWD"] = workspacePath
launcherEnvironment["GITHUB_WORKSPACE"] = workspacePath
launcherEnvironment["GHOSTHUB_TEST_STOP_GRACE"] = "2"
let state = LaunchState()
let signalStatuses: [(Int32, Int32)] = [
    (SIGINT, 130),
    (SIGTERM, 143),
    (SIGHUP, 129),
]
let signalSources = signalStatuses.map { signalNumber, status in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(
        signal: signalNumber,
        queue: state.queue
    )
    source.setEventHandler {
        guard state.cancellationStatus == nil else {
            return
        }
        state.cancellationSignal = signalNumber
        state.cancellationStatus = status
        if let launcherPID = state.launcherPID {
            _ = signalVerifiedLauncher(
                bundleIdentifier: bundleIdentifier,
                applicationURL: applicationURL,
                launcherPID: launcherPID,
                signalNumber: signalNumber
            )
        }
    }
    source.resume()
    return source
}

if let cancellationStatus = state.queue.sync(
    execute: { state.cancellationStatus }
) {
    exit(cancellationStatus)
}

guard !applicationArguments.isEmpty else {
    fputs("GUI launcher arguments are missing.\n", stderr)
    exit(2)
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
configuration.addsToRecentItems = false
configuration.allowsRunningApplicationSubstitution = false
configuration.createsNewApplicationInstance = true
configuration.promptsUserIfNeeded = false
configuration.arguments = applicationArguments
configuration.environment = launcherEnvironment

NSWorkspace.shared.openApplication(
    at: applicationURL,
    configuration: configuration
) { runningApplication, error in
    state.queue.sync {
        defer { state.launchCompleted = true }
        if let error {
            state.failure = "Could not launch GUI tests: \(error)"
            return
        }
        guard let runningApplication else {
            state.failure =
                "LaunchServices did not return a GUI launcher"
            return
        }
        let launcherPID = runningApplication.processIdentifier
        guard runningApplication.bundleIdentifier == bundleIdentifier else {
            state.failure = "LaunchServices returned the wrong launcher identifier"
            return
        }
        guard runningApplication.bundleURL?.standardizedFileURL == applicationURL else {
            state.failure = "LaunchServices returned the wrong launcher URL"
            return
        }
        guard launcherPID > 0 else {
            state.failure = "LaunchServices returned an invalid launcher PID"
            return
        }
        guard getpgid(launcherPID) == launcherPID else {
            state.failure = "LaunchServices returned a launcher outside its process group"
            return
        }

        state.launcherApplication = runningApplication
        state.launcherPID = launcherPID
        do {
            try "\(launcherPID)\n".write(
                to: pidFileURL,
                atomically: true,
                encoding: .utf8
            )
            if let cancellationSignal = state.cancellationSignal {
                _ = signalVerifiedLauncher(
                    bundleIdentifier: bundleIdentifier,
                    applicationURL: applicationURL,
                    launcherPID: launcherPID,
                    signalNumber: cancellationSignal
                )
            }
        } catch {
            state.failure = "Could not publish GUI launcher PID: \(error)"
            _ = signalVerifiedLauncher(
                bundleIdentifier: bundleIdentifier,
                applicationURL: applicationURL,
                launcherPID: launcherPID,
                signalNumber: SIGKILL
            )
        }
    }
}

withExtendedLifetime(signalSources) {
    while true {
        let launchCompleted = state.queue.sync { state.launchCompleted }
        if launchCompleted {
            break
        }
        RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.01)
        )
    }
    var stopStartedAt: Date?
    var killSent = false
    while true {
        let launcherState: (running: Bool, pid: pid_t?, cancelled: Bool) = state.queue.sync {
            guard let launcherApplication = state.launcherApplication else {
                return (running: false, pid: nil, cancelled: false)
            }
            return (
                running: !launcherApplication.isTerminated,
                pid: state.launcherPID,
                cancelled: state.cancellationStatus != nil
            )
        }
        guard let launcherPID = launcherState.pid else {
            break
        }
        let groupStatus = signalProcessGroup(
            processGroup: launcherPID,
            signalNumber: 0
        )
        if groupStatus == launcherAbsentStatus {
            break
        }
        if groupStatus == 1 {
            state.queue.sync {
                state.failure = "Could not inspect the GUI launcher process group"
            }
            break
        }
        if stopStartedAt == nil,
           !launcherState.running || launcherState.cancelled || FileManager.default
           .fileExists(atPath: completionFileURL.path) {
            let signalStatus = signalProcessGroup(
                processGroup: launcherPID,
                signalNumber: SIGTERM
            )
            if signalStatus == 1 {
                state.queue.sync {
                    state.failure = "Could not stop the GUI launcher process group"
                }
            }
            stopStartedAt = Date()
        }
        if let stopStartedAt,
           !killSent,
           Date().timeIntervalSince(stopStartedAt) >= 2 {
            let signalStatus = signalProcessGroup(
                processGroup: launcherPID,
                signalNumber: SIGKILL
            )
            if signalStatus == 1 {
                state.queue.sync {
                    state.failure = "Could not kill the GUI launcher process group"
                }
                break
            }
            killSent = true
        }
        RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.01)
        )
    }
}
let finalState = state.queue.sync {
    let processGroupTerminated: Bool
    if let launcherPID = state.launcherPID {
        processGroupTerminated = signalProcessGroup(
            processGroup: launcherPID,
            signalNumber: 0
        ) == launcherAbsentStatus
    } else {
        processGroupTerminated = true
    }
    if processGroupTerminated {
        state.launcherPID = nil
    } else if state.failure == nil {
        state.failure =
            "GUI launcher process group remained after cleanup"
    }
    return (
        cancellationStatus: state.cancellationStatus,
        failure: state.failure,
        processGroupTerminated: processGroupTerminated
    )
}
if finalState.processGroupTerminated {
    _ = try? FileManager.default.removeItem(at: pidFileURL)
}
if let failure = finalState.failure {
    fputs("\(failure)\n", stderr)
}
if let cancellationStatus = finalState.cancellationStatus {
    exit(cancellationStatus)
}
if finalState.failure != nil {
    exit(1)
}
exit(0)
