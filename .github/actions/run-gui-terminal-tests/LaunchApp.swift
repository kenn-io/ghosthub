import AppKit
import Darwin
import Foundation
import XCTest

private func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(status)
}

private func redirectOutput(to path: String) {
    let descriptor = open(path, O_WRONLY | O_APPEND)
    guard descriptor >= 0 else {
        perror("Could not open GUI test output")
        exit(1)
    }
    guard dup2(descriptor, STDOUT_FILENO) >= 0,
          dup2(descriptor, STDERR_FILENO) >= 0
    else {
        perror("Could not redirect GUI test output")
        exit(1)
    }
    close(descriptor)
}

private func leafTests(in test: XCTest) -> [XCTest] {
    guard let suite = test as? XCTestSuite else {
        return [test]
    }
    return suite.tests.flatMap(leafTests(in:))
}

@_cdecl("ghosthub_run_gui_tests")
public func runGUITests() -> Int32 {
    guard CommandLine.arguments.count == 7 else {
        fail(
            "usage: launcher ready-file result-file output-file test-bundle filter workspace",
            status: 2
        )
    }

    let readyFileURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let resultFileURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let outputPath = CommandLine.arguments[3]
    let testBundleURL = URL(fileURLWithPath: CommandLine.arguments[4])
    let filter = CommandLine.arguments[5]

    redirectOutput(to: outputPath)

    guard getpgrp() == getpid() else {
        fail("GUI launcher process group was not isolated")
    }

    let application = NSApplication.shared
    guard application.setActivationPolicy(.regular) else {
        fail("Could not activate the GUI test application")
    }
    application.finishLaunching()
    application.activate(ignoringOtherApps: true)

    do {
        try Data().write(to: readyFileURL, options: .atomic)
    } catch {
        fail("Could not publish GUI launcher readiness: \(error)")
    }

    guard let testBundle = Bundle(url: testBundleURL) else {
        fail("Could not open the GUI XCTest bundle")
    }
    do {
        try testBundle.loadAndReturnError()
    } catch {
        fail("Could not load the GUI XCTest bundle: \(error)")
    }

    let expression: NSRegularExpression
    do {
        expression = try NSRegularExpression(pattern: filter)
    } catch {
        fail("Invalid GUI XCTest filter: \(error)")
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
        fail("The GUI XCTest filter selected no tests")
    }

    selected.run()
    guard let testRun = selected.testRun else {
        fail("GUI XCTest did not report a result")
    }
    let status = testRun.hasSucceeded && testRun.skipCount == 0 ? 0 : 1
    do {
        try "\(status)\n".write(
            to: resultFileURL,
            atomically: true,
            encoding: .utf8
        )
    } catch {
        fail("Could not publish GUI XCTest result: \(error)")
    }
    return Int32(status)
}
