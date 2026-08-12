import os

/// Render-path work counters behind the activation work gate
/// (`ActivationWorkGateTests`). Key-window switches must stay cheap, so the
/// gate bounds how much counted work a switch may trigger. Counting is
/// opt-in: outside an explicit recording window every count call is a
/// single flag check, so unrelated test suites exercising these views can
/// neither race the gate nor pollute its counts, and release builds keep
/// the shipping code path the gate measures.
enum RenderWorkCounters {
    struct Counts {
        var rootBodyEvaluations = 0
        var sidebarSectionComputations = 0
        fileprivate var isRecording = false
    }

    private static let state = OSAllocatedUnfairLock(
        initialState: Counts()
    )

    static func countRootBodyEvaluation() {
        state.withLock {
            guard $0.isRecording else { return }
            $0.rootBodyEvaluations += 1
        }
    }

    static func countSidebarSectionComputation() {
        state.withLock {
            guard $0.isRecording else { return }
            $0.sidebarSectionComputations += 1
        }
    }

    static func beginRecording() {
        state.withLock { $0 = Counts(isRecording: true) }
    }

    static func endRecording() -> Counts {
        state.withLock {
            let counts = $0
            $0 = Counts()
            return counts
        }
    }
}
