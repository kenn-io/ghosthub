import Testing
@testable import GhosthubTerminalSupport

@Suite("Display availability")
struct DisplayAvailabilityTests {
    @Test(
        "surface creation failure is retryable only with no active display",
        arguments: [
            (activeDisplayCount: 0, expected: true),
            (activeDisplayCount: 1, expected: false),
            (activeDisplayCount: 2, expected: false),
        ]
    )
    func surfaceCreationFailureRetryability(
        activeDisplayCount: Int,
        expected: Bool
    ) {
        #expect(
            DisplayAvailability.surfaceCreationFailureIsRetryable(
                activeDisplayCount: activeDisplayCount
            ) == expected
        )
    }
}
