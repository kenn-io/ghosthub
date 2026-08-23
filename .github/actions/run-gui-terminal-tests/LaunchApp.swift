import AppKit
import Darwin
import Foundation
import XCTest

private struct LauncherFailure: Error {
    let message: String
    let status: Int32
}

private func fail(_ message: String, status: Int32 = 1) throws -> Never {
    throw LauncherFailure(message: message, status: status)
}

private func redirectOutput(to path: String) throws {
    let descriptor = open(path, O_WRONLY | O_APPEND)
    guard descriptor >= 0 else {
        try fail(
            "Could not open GUI test output: \(String(cString: strerror(errno)))"
        )
    }
    guard dup2(descriptor, STDOUT_FILENO) >= 0,
          dup2(descriptor, STDERR_FILENO) >= 0
    else {
        let message = String(cString: strerror(errno))
        close(descriptor)
        try fail("Could not redirect GUI test output: \(message)")
    }
    close(descriptor)
}

private func leafTests(in test: XCTest) -> [XCTest] {
    guard let suite = test as? XCTestSuite else {
        return [test]
    }
    return suite.tests.flatMap(leafTests(in:))
}

private func executeGUITests() throws -> Int32 {
    guard CommandLine.arguments.count == 8 else {
        try fail(
            "usage: launcher ready-file result-file output-file test-bundle filter workspace completion-file",
            status: 2
        )
    }

    let readyFileURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let resultFileURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let outputPath = CommandLine.arguments[3]
    let testBundleURL = URL(fileURLWithPath: CommandLine.arguments[4])
    let filter = CommandLine.arguments[5]

    try redirectOutput(to: outputPath)

    guard getpgrp() == getpid() else {
        try fail("GUI launcher process group was not isolated")
    }

    let application = NSApplication.shared
    guard application.setActivationPolicy(.regular) else {
        try fail("Could not activate the GUI test application")
    }
    application.finishLaunching()
    application.activate(ignoringOtherApps: true)

    do {
        try Data().write(to: readyFileURL, options: .atomic)
    } catch {
        try fail("Could not publish GUI launcher readiness: \(error)")
    }

    guard let testBundle = Bundle(url: testBundleURL) else {
        try fail("Could not open the GUI XCTest bundle")
    }
    do {
        try testBundle.loadAndReturnError()
    } catch {
        try fail("Could not load the GUI XCTest bundle: \(error)")
    }

    let expression: NSRegularExpression
    do {
        expression = try NSRegularExpression(pattern: filter)
    } catch {
        try fail("Invalid GUI XCTest filter: \(error)")
    }

    let selected = XCTestSuite(name: "Selected GUI tests")
    for test in leafTests(in: XCTestSuite.default) {
        let typeName = String(reflecting: type(of: test))
        guard typeName.hasPrefix("GhosthubTerminalSmokeTests.") else {
            continue
        }
        let identity = "\(typeName)/\(test.name)"
        let range = NSRange(identity.startIndex..., in: identity)
        if expression.firstMatch(in: identity, range: range) != nil {
            selected.addTest(test)
        }
    }
    guard selected.testCaseCount > 0 else {
        try fail("The GUI XCTest filter selected no tests")
    }

    selected.run()
    guard let testRun = selected.testRun else {
        try fail("GUI XCTest did not report a result")
    }
    let status = testRun.hasSucceeded && testRun.skipCount == 0 ? 0 : 1
    do {
        try "\(status)\n".write(
            to: resultFileURL,
            atomically: true,
            encoding: .utf8
        )
    } catch {
        try fail("Could not publish GUI XCTest result: \(error)")
    }
    return Int32(status)
}

@_cdecl("ghosthub_run_gui_tests")
public func runGUITests() -> Int32 {
    do {
        return try executeGUITests()
    } catch let failure as LauncherFailure {
        FileHandle.standardError.write(Data("\(failure.message)\n".utf8))
        return failure.status
    } catch {
        FileHandle.standardError.write(Data("Unexpected GUI test failure: \(error)\n".utf8))
        return 1
    }
}
