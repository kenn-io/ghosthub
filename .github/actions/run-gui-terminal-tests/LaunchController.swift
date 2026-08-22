import AppKit
import Darwin
import Foundation

let launcherAbsentStatus: Int32 = 3

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
    if kill(-launcherPID, signalNumber) == 0 {
        return 0
    }
    if errno == ESRCH {
        return launcherAbsentStatus
    }
    return 1
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

guard CommandLine.arguments.count >= 7 else {
    fputs(
        "usage: launch-controller bundle-id app pid-file stdout stderr arguments...\n",
        stderr
    )
    exit(2)
}

let bundleIdentifier = CommandLine.arguments[1]
let applicationURL = URL(
    fileURLWithPath: CommandLine.arguments[2]
).standardizedFileURL
let pidFileURL = URL(fileURLWithPath: CommandLine.arguments[3])
let standardOutputPath = CommandLine.arguments[4]
let standardErrorPath = CommandLine.arguments[5]
let applicationArguments = Array(CommandLine.arguments.dropFirst(6))
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

guard let launcherScript = applicationArguments.first else {
    fputs("GUI launcher arguments are missing.\n", stderr)
    exit(2)
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
configuration.addsToRecentItems = false
configuration.allowsRunningApplicationSubstitution = false
configuration.createsNewApplicationInstance = true
configuration.promptsUserIfNeeded = false
configuration.arguments = [
    launcherScript,
    CommandLine.arguments[3] + ".ready",
    standardOutputPath,
    standardErrorPath,
] + Array(applicationArguments.dropFirst())

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
        guard let runningApplication,
              runningApplication.bundleIdentifier == bundleIdentifier,
              runningApplication.bundleURL?.standardizedFileURL == applicationURL,
              runningApplication.processIdentifier > 0,
              getpgid(runningApplication.processIdentifier) ==
              runningApplication.processIdentifier
        else {
            state.failure =
                "LaunchServices returned an unauthenticated GUI launcher"
            return
        }

        let launcherPID = runningApplication.processIdentifier
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
    while true {
        let launcherRunning = state.queue.sync {
            guard let launcherApplication = state.launcherApplication else {
                return false
            }
            return !launcherApplication.isTerminated
        }
        if !launcherRunning {
            break
        }
        RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.01)
        )
    }
}
let finalState = state.queue.sync {
    let launcherTerminated: Bool
    if let launcherPID = state.launcherPID {
        launcherTerminated = signalVerifiedLauncher(
            bundleIdentifier: bundleIdentifier,
            applicationURL: applicationURL,
            launcherPID: launcherPID,
            signalNumber: 0
        ) == launcherAbsentStatus
    } else {
        launcherTerminated = true
    }
    if launcherTerminated {
        state.launcherPID = nil
    } else if state.failure == nil {
        state.failure =
            "GUI launcher remained running after termination was reported"
    }
    return (
        cancellationStatus: state.cancellationStatus,
        failure: state.failure,
        launcherTerminated: launcherTerminated
    )
}
if finalState.launcherTerminated {
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
