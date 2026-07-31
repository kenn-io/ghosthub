import Testing
@testable import GhosthubApp

@Suite("Application version")
struct ApplicationVersionTests {
    @Test("development metadata supplies the About version")
    func developmentAboutVersion() {
        let version = ApplicationVersion.aboutPanelVersion(
            infoDictionary: [
                "CFBundleShortVersionString": "0.3.0",
                "GhosthubDevelopmentVersion": "0.3.0-8-g3c67741-dirty",
            ]
        )

        #expect(version == "0.3.0-8-g3c67741-dirty")
    }

    @Test("release builds use the numeric short version")
    func releaseAboutVersion() {
        let version = ApplicationVersion.aboutPanelVersion(
            infoDictionary: [
                "CFBundleShortVersionString": "0.3.0",
            ]
        )

        #expect(version == "0.3.0")
    }
}
