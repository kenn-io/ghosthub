import GhosthubTestSupport
import Testing
@testable import GhosthubWorkspace

struct ProjectRepositoryIdentityTests {
    @Test("platform repository identity handles nested and self-hosted URLs")
    func platformRepositoryIdentity() {
        let gitLab = ProjectSummary.fixture(
            platformURL: "https://gitlab.com/group/subgroup/app.git"
        )
        #expect(gitLab.platformRepositoryFullName == "group/subgroup/app")
        #expect(gitLab.platformRepositoryHost == "gitlab.com")
        #expect(gitLab.platformRepositoryProvider == "gitlab")

        let selfHosted = ProjectSummary.fixture(
            platformURL: "git@git.corp.com:acme/app.git"
        )
        #expect(selfHosted.platformRepositoryFullName == "acme/app")
        #expect(selfHosted.platformRepositoryHost == "git.corp.com")
        #expect(selfHosted.platformRepositoryProvider == "github")
    }
}
