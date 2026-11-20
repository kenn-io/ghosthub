import Foundation
import Testing
@testable import GhosthubUI

struct ProjectPathInputTests {
    @Test("picked folders differing by trailing whitespace remain distinct")
    func pickedPaths() {
        var input = ProjectPathInput()
        for path in ["/code/Notes", "/code/Notes ", "/code/Notes\n"] {
            input.selectFolder(URL(fileURLWithPath: path, isDirectory: true))
            #expect(Array(input.submissionPath(recovering: false).utf8) == Array(path.utf8))
            #expect(Array(input.submissionPath(recovering: true).utf8) == Array(path.utf8))
        }
        input.text = "  /code/Manual  "
        #expect(input.submissionPath(recovering: false) == "/code/Manual")
        #expect(input.submissionPath(recovering: true) == "  /code/Manual  ")
    }
}
