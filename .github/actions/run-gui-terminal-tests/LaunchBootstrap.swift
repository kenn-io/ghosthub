import AppKit
import Darwin
import Foundation

guard CommandLine.arguments.count == 7 else {
    fputs(
        "usage: launcher ready-file result-file output-file test-bundle filter workspace\n",
        stderr
    )
    exit(2)
}

// Keep the authenticated process-group leader available while cancellation
// drains its children. An executed helper resets these caught handlers to the
// default disposition, while cleanup can still authenticate this application
// and escalate the complete group to SIGKILL.
for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    signal(signalNumber) { _ in }
}

private func loaderError() -> String {
    guard let message = dlerror() else {
        return "unknown dynamic-loader error"
    }
    return String(cString: message)
}

guard setpgid(0, 0) == 0, getpgrp() == getpid() else {
    perror("Could not isolate GUI launcher process group")
    exit(1)
}

guard chdir(CommandLine.arguments[6]) == 0 else {
    perror("Could not enter the GUI test workspace")
    exit(1)
}

// Register the lightweight bundle with AppKit before loading XCTest and the
// package test bundle. The controller can then authenticate this exact app and
// process group without racing the heavier test runtime startup.
_ = NSApplication.shared

if CommandLine.arguments.count > 3 {
    let output = open(CommandLine.arguments[3], O_WRONLY | O_APPEND)
    if output >= 0 {
        _ = dup2(output, STDOUT_FILENO)
        _ = dup2(output, STDERR_FILENO)
        close(output)
    }
}

let launcherURL = URL(fileURLWithPath: CommandLine.arguments[0])
let libraryURL = launcherURL
    .deletingLastPathComponent()
    .appendingPathComponent("test-launcher.dylib")
guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
    fputs("Could not load GUI test launcher: \(loaderError())\n", stderr)
    exit(1)
}
guard let symbol = dlsym(library, "ghosthub_run_gui_tests") else {
    fputs(
        "Could not find GUI test launcher entry point: \(loaderError())\n",
        stderr
    )
    exit(1)
}
let runTests = unsafeBitCast(
    symbol,
    to: (@convention(c) () -> Int32).self
)
exit(runTests())
