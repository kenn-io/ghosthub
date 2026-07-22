import Foundation
import Testing
@testable import GhosthubWorkspace

struct KnownAgentTests {
    @Test(
        "recognize maps supported agent executable names",
        arguments: [
            ("claude", WorkspaceKnownAgent.claude),
            ("codex --yolo", WorkspaceKnownAgent.codex),
            ("  codex\t--yolo  ", WorkspaceKnownAgent.codex),
            ("opencode", WorkspaceKnownAgent.opencode),
            ("gemini", WorkspaceKnownAgent.gemini),
            ("copilot", WorkspaceKnownAgent.copilot),
        ]
    )
    func recognizeSupportedExecutableNames(
        executableName: String,
        expectedAgent: WorkspaceKnownAgent
    ) {
        #expect(
            WorkspaceKnownAgent.recognize(
                executableName: executableName
            ) == expectedAgent
        )
    }

    @Test(
        "recognize returns nil for unsupported executables",
        arguments: [
            "",
            "zsh",
            "/bin/bash",
            "python3",
            "gh",
        ]
    )
    func recognizeUnsupportedExecutableNames(
        executableName: String
    ) {
        #expect(
            WorkspaceKnownAgent.recognize(
                executableName: executableName
            ) == nil
        )
    }
}
