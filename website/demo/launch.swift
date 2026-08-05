#!/usr/bin/env swift

import AppKit
import Darwin
import Foundation

private struct LaunchFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func stop(_ application: NSRunningApplication) {
    _ = application.terminate()
    let gracefulDeadline = Date().addingTimeInterval(3)
    while !application.isTerminated, Date() < gracefulDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    if !application.isTerminated {
        _ = application.forceTerminate()
        let forcedDeadline = Date().addingTimeInterval(1)
        while !application.isTerminated, Date() < forcedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
    if !application.isTerminated {
        _ = Darwin.kill(application.processIdentifier, SIGKILL)
        let killedDeadline = Date().addingTimeInterval(1)
        while !application.isTerminated, Date() < killedDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

guard CommandLine.arguments.count == 9 else {
    fail(
        "usage: launch.swift APP EXECUTABLE OWNERSHIP_RECORD PID_RECORD HOSTS_HEX DEMO_ROOT SCRATCH SSH_AUTH_SOCK"
    )
}

let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let expectedExecutable = URL(fileURLWithPath: CommandLine.arguments[2])
    .resolvingSymlinksInPath().standardizedFileURL
let ownershipRecordURL = URL(fileURLWithPath: CommandLine.arguments[3])
let publishedRecordURL = URL(fileURLWithPath: CommandLine.arguments[4])
let hostsHex = CommandLine.arguments[5]
let demoRoot = CommandLine.arguments[6]
let scratch = CommandLine.arguments[7]
let sshAuthSocket = CommandLine.arguments[8]

// Once LaunchServices has created the application, this helper must run until
// it either publishes the exact PID or terminates that exact application. The
// parent shell owns signal handling and cleanup after the PID record exists.
_ = Darwin.signal(SIGHUP, SIG_IGN)
_ = Darwin.signal(SIGINT, SIG_IGN)
_ = Darwin.signal(SIGTERM, SIG_IGN)

let configuration = NSWorkspace.OpenConfiguration()
configuration.arguments = [
    "-ApplePersistenceIgnoreState", "YES",
    "-ghosthub.settings.hosts.ssh", "<\(hostsHex)>",
]
configuration.createsNewApplicationInstance = true
configuration.environment = [
    "HOME": "\(scratch)/home",
    "ZDOTDIR": "\(scratch)/home",
    "SHELL": "/bin/zsh",
    "GHOSTHUB_CONFIG_HOME": "\(scratch)/ghosthub-config",
    "GHOSTHUB_STATE_HOME": "\(scratch)/ghosthub-state",
    "GHOSTHUB_DEMO_ROOT": demoRoot,
    "GHOSTHUB_DEMO_SCRATCH": scratch,
    "GHOSTHUB_DEMO_SSH_DIR": "\(scratch)/ssh",
    "TMUX_TMPDIR": "\(scratch)/tmux",
    "DYLD_INSERT_LIBRARIES": "\(scratch)/libdemohost.dylib",
]
if !sshAuthSocket.isEmpty {
    configuration.environment["SSH_AUTH_SOCK"] = sshAuthSocket
}

var launchedApplication: NSRunningApplication?
var launchError: Error?
var launchFinished = false
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) {
    application, error in
    launchedApplication = application
    launchError = error
    launchFinished = true
}
while !launchFinished {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

guard let application = launchedApplication else {
    fail(
        "LaunchServices could not open the demo application: \(launchError?.localizedDescription ?? "unknown error")"
    )
}
guard let launchedExecutable = application.executableURL?
    .resolvingSymlinksInPath().standardizedFileURL,
    launchedExecutable == expectedExecutable
else {
    stop(application)
    fail("LaunchServices returned an application with an unexpected executable")
}

let temporaryRecord = ownershipRecordURL.deletingLastPathComponent()
    .appendingPathComponent(".app.pid.\(UUID().uuidString).tmp")
do {
    try Data("\(application.processIdentifier)\n".utf8)
        .write(to: temporaryRecord, options: .withoutOverwriting)
    guard link(temporaryRecord.path, ownershipRecordURL.path) == 0 else {
        throw LaunchFailure(
            message: "cannot publish launch ownership: \(String(cString: strerror(errno)))"
        )
    }
    try FileManager.default.removeItem(at: temporaryRecord)
    guard link(ownershipRecordURL.path, publishedRecordURL.path) == 0 else {
        throw LaunchFailure(
            message: "cannot publish demo PID record: \(String(cString: strerror(errno)))"
        )
    }
} catch {
    try? FileManager.default.removeItem(at: temporaryRecord)
    try? FileManager.default.removeItem(at: ownershipRecordURL)
    stop(application)
    if !application.isTerminated {
        fail("cannot record or terminate launched demo application: \(error.localizedDescription)")
    }
    fail("cannot record launched demo application: \(error.localizedDescription)")
}
