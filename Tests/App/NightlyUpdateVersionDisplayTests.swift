import Foundation
import Testing
@testable import GhosthubApp

@Suite("Nightly update versions")
struct NightlyUpdateVersionDisplayTests {
    @Test("nightly builds on the same day have distinct update labels")
    func sameDayBuilds() {
        let display = NightlyUpdateVersionDisplay(infoDictionary: [
            "GhosthubDevelopmentVersion": "Nightly · 2026-08-13 · abcdef12",
        ])
        let updateDate = ISO8601DateFormatter().date(from: "2026-08-13T00:30:00Z")!

        #expect(display.installedVersion(build: "123") == "Nightly · 2026-08-13 · build 123")
        #expect(display
            .updateVersion(date: updateDate, build: "124") == "Nightly · 2026-08-13 · build 124")
    }

    @Test("nightly labels keep the build when dates are absent")
    func missingDates() {
        let display = NightlyUpdateVersionDisplay(infoDictionary: [:])

        #expect(display.installedVersion(build: "123") == "Nightly · build 123")
        #expect(display.updateVersion(date: nil, build: "124") == "Nightly · build 124")
    }
}
