import AppKit
import Darwin
import Foundation

guard CommandLine.arguments.count >= 6 else {
    fputs(
        "usage: launcher script ready-file stdout stderr arguments...\n",
        stderr
    )
    exit(2)
}

let launcherScript = CommandLine.arguments[1]
let readyFileURL = URL(fileURLWithPath: CommandLine.arguments[2])
let standardOutputPath = CommandLine.arguments[3]
let standardErrorPath = CommandLine.arguments[4]
let launcherArguments = [
    launcherScript,
    readyFileURL.path,
] + Array(CommandLine.arguments.dropFirst(5))

let standardOutputFD = open(standardOutputPath, O_WRONLY | O_APPEND)
guard standardOutputFD >= 0 else {
    perror("Could not open GUI launcher stdout")
    exit(1)
}
let standardErrorFD = open(standardErrorPath, O_WRONLY | O_APPEND)
guard standardErrorFD >= 0 else {
    perror("Could not open GUI launcher stderr")
    exit(1)
}
guard dup2(standardOutputFD, STDOUT_FILENO) >= 0,
      dup2(standardErrorFD, STDERR_FILENO) >= 0
else {
    perror("Could not redirect GUI launcher output")
    exit(1)
}
close(standardOutputFD)
close(standardErrorFD)

guard setpgid(0, 0) == 0, getpgrp() == getpid() else {
    perror("Could not isolate GUI launcher process group")
    exit(1)
}
for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    signal(signalNumber) { _ in }
}

var spawnAttributes: posix_spawnattr_t?
guard posix_spawnattr_init(&spawnAttributes) == 0 else {
    fputs("Could not initialize GUI test spawn attributes.\n", stderr)
    exit(1)
}
defer { posix_spawnattr_destroy(&spawnAttributes) }
var defaultSignals = sigset_t()
sigemptyset(&defaultSignals)
for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    sigaddset(&defaultSignals, signalNumber)
}
guard posix_spawnattr_setflags(
    &spawnAttributes,
    Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF)
) == 0,
    posix_spawnattr_setpgroup(&spawnAttributes, getpgrp()) == 0,
    posix_spawnattr_setsigdefault(&spawnAttributes, &defaultSignals) == 0
else {
    fputs("Could not configure GUI test spawn attributes.\n", stderr)
    exit(1)
}

let argumentStrings = ["/bin/bash"] + launcherArguments
var cArguments = argumentStrings.map { strdup($0) }
defer { cArguments.forEach { free($0) } }
cArguments.append(nil)
var testPID = pid_t(0)
let spawnStatus = "/bin/bash".withCString { executablePath in
    cArguments.withUnsafeMutableBufferPointer { arguments in
        posix_spawn(
            &testPID,
            executablePath,
            nil,
            &spawnAttributes,
            arguments.baseAddress!,
            environ
        )
    }
}
guard spawnStatus == 0, testPID > 0 else {
    fputs("Could not start GUI test wrapper.\n", stderr)
    exit(1)
}
guard getpgid(testPID) == getpgrp() else {
    fputs("GUI test wrapper escaped the launcher process group.\n", stderr)
    _ = kill(testPID, SIGKILL)
    _ = waitpid(testPID, nil, 0)
    exit(1)
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
application.finishLaunching()
application.activate(ignoringOtherApps: true)
do {
    try Data().write(to: readyFileURL, options: .atomic)
} catch {
    fputs("Could not publish GUI launcher readiness: \(error)\n", stderr)
    _ = kill(-getpgrp(), SIGKILL)
    exit(1)
}

var waitStatus = Int32(0)
while true {
    let waitedPID = waitpid(testPID, &waitStatus, WNOHANG)
    if waitedPID == testPID {
        break
    }
    if waitedPID == -1 {
        if errno == EINTR {
            continue
        }
        perror("Could not wait for GUI test wrapper")
        exit(1)
    }
    RunLoop.current.run(
        mode: .default,
        before: Date(timeIntervalSinceNow: 0.01)
    )
}
if waitStatus & 0x7f == 0 {
    exit((waitStatus >> 8) & 0xff)
}
exit(128 + (waitStatus & 0x7f))
