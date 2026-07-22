import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("ResourceMonitoringPolicy")
struct ResourceMonitoringPolicyTests {
    @Test("resource monitoring is available only for local hosts")
    func availableOnlyForLocalHosts() {
        let localHostID = UUID()
        let remoteHostID = UUID()
        let snapshot = WorkspaceSnapshot(
            hosts: [
                HostSummary(
                    id: localHostID,
                    name: "This Mac",
                    kind: .selfHost,
                    platform: .macOS
                ),
                HostSummary(
                    id: remoteHostID,
                    name: "Office Linux",
                    kind: .remote,
                    platform: .linux
                ),
            ],
            projects: [],
            worktrees: []
        )

        #expect(
            ResourceMonitoringPolicy.isAvailable(
                for: localHostID,
                in: snapshot
            )
        )
        #expect(
            !ResourceMonitoringPolicy.isAvailable(
                for: remoteHostID,
                in: snapshot
            )
        )
        #expect(
            !ResourceMonitoringPolicy.isAvailable(
                for: nil,
                in: snapshot
            )
        )
    }

    @Test("resource monitoring refresh backs off when inactive")
    func refreshIntervalBacksOffWhenInactive() {
        #expect(
            ResourceMonitoringPolicy.refreshIntervalSeconds(
                isAppActive: true
            ) == 5
        )
        #expect(
            ResourceMonitoringPolicy.refreshIntervalSeconds(
                isAppActive: false
            ) == 30
        )
    }

    @Test("resource trace logging requires explicit flag")
    func resourceTraceLoggingRequiresExplicitFlag() {
        #expect(
            !ResourceMonitoringPolicy.traceEnabled(environment: [:])
        )
        #expect(
            !ResourceMonitoringPolicy.traceEnabled(
                environment: ["GHOSTHUB_RESOURCE_TRACE": "0"]
            )
        )
        #expect(
            ResourceMonitoringPolicy.traceEnabled(
                environment: ["GHOSTHUB_RESOURCE_TRACE": "1"]
            )
        )
    }

    @Test("active loop plan samples immediately")
    func activeLoopPlanSamplesImmediately() {
        let plan = ResourceMonitoringPolicy.loopPlan(
            isAppActive: true
        )
        #expect(plan.refreshIntervalSeconds == 5)
        #expect(plan.sampleImmediately)
    }

    @Test("inactive loop plan backs off without immediate sampling")
    func inactiveLoopPlanBacksOff() {
        let plan = ResourceMonitoringPolicy.loopPlan(
            isAppActive: false
        )
        #expect(plan.refreshIntervalSeconds == 30)
        #expect(!plan.sampleImmediately)
    }
}
