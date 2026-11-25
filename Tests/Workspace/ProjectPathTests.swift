import GhosthubWorkspace
import Testing

@Suite("Project path validation")
struct ProjectPathTests {
    @Test(
        "accepts absolute and home-relative POSIX paths",
        arguments: [
            "/",
            "/code/widget",
            "~",
            "~/",
            "~/code/widget",
            "~/my projects/widget",
        ]
    )
    func acceptsValidUserInput(path: String) {
        #expect(ProjectPath.isValidUserInput(path))
    }

    @Test(
        "rejects relative and other-user tilde paths",
        arguments: [
            "",
            "relative/widget",
            "./widget",
            "../widget",
            "~other/widget",
            " ~",
            " /code/widget",
        ]
    )
    func rejectsInvalidUserInput(path: String) {
        #expect(!ProjectPath.isValidUserInput(path))
    }
}
