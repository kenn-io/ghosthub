import Testing
@testable import GhosthubApp

@Suite("Workspace tab adoption")
struct WorkspaceTabAdoptionPolicyTests {
    @Test("a newly opened workspace joins the requesting window")
    func adoptsNewWorkspace() {
        #expect(
            WorkspaceTabAdoptionPolicy.action(
                hasPendingParent: true,
                isParentWindow: false,
                isAlreadyGrouped: false
            ) == .adopt
        )
    }

    @Test("an AppKit-grouped workspace only consumes the pending request")
    func finishesAutomaticAdoption() {
        #expect(
            WorkspaceTabAdoptionPolicy.action(
                hasPendingParent: true,
                isParentWindow: false,
                isAlreadyGrouped: true
            ) == .finish
        )
    }

    @Test(
        "the requesting window and unrelated appearances do not consume the request",
        arguments: [
            (false, false),
            (true, true),
        ]
    )
    func ignoresNonCandidates(
        hasPendingParent: Bool,
        isParentWindow: Bool
    ) {
        #expect(
            WorkspaceTabAdoptionPolicy.action(
                hasPendingParent: hasPendingParent,
                isParentWindow: isParentWindow,
                isAlreadyGrouped: false
            ) == .ignore
        )
    }
}
