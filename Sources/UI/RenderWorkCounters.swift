/// Render-path work counters behind the activation work gate
/// (`ActivationWorkGateTests`). Key-window switches must stay cheap, so the
/// gate bounds how much counted work a switch may trigger. Counting stays
/// compiled into release builds so the gate exercises the shipping code
/// path; the storage is `nonisolated(unsafe)` because every counted call
/// site runs on the main thread during view updates.
enum RenderWorkCounters {
    private(set) nonisolated(unsafe) static var rootBodyEvaluations = 0
    private(set) nonisolated(unsafe) static var sidebarSectionComputations = 0

    static func countRootBodyEvaluation() {
        rootBodyEvaluations += 1
    }

    static func countSidebarSectionComputation() {
        sidebarSectionComputations += 1
    }

    static func reset() {
        rootBodyEvaluations = 0
        sidebarSectionComputations = 0
    }
}
