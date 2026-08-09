import Foundation
@testable import GhosthubUI
import Testing

@Suite("New Herdr session validation")
struct NewHerdrSessionSheetTests {
    @Test(
        "names follow Herdr's portable session contract",
        arguments: [
            ("release.review-2", true),
            ("_agent", true),
            (".", false),
            ("..", false),
            ("two words", false),
            ("é", false),
            (String(repeating: "a", count: 64), true),
            (String(repeating: "a", count: 65), false),
        ]
    )
    func nameValidation(name: String, expected: Bool) {
        #expect(HerdrSessionName.isValid(name) == expected)
    }

    @Test("existing names direct the user to restart")
    func collisionMessage() {
        #expect(HerdrSessionName.validationMessage(
            " review ",
            existingNames: ["review"]
        ) == "A Herdr session named “review” already exists on this host. Restart it instead.")
    }
}
