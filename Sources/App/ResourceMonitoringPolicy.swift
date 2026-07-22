import Foundation
import GhosthubWorkspace

struct ResourceMonitoringPlan: Equatable, Sendable {
    let refreshIntervalSeconds: Int
    let sampleImmediately: Bool

    init(
        refreshIntervalSeconds: Int,
        sampleImmediately: Bool
    ) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.sampleImmediately = sampleImmediately
    }
}

enum ResourceMonitoringPolicy {
    static func isAvailable(
        for hostID: UUID?,
        in snapshot: WorkspaceSnapshot
    ) -> Bool {
        guard let hostID else {
            return false
        }
        return snapshot.host(id: hostID)?.kind == .selfHost
    }

    static func refreshIntervalSeconds(
        isAppActive: Bool
    ) -> Int {
        isAppActive ? 5 : 30
    }

    static func traceEnabled(
        environment: [String: String]
    ) -> Bool {
        environment["GHOSTHUB_RESOURCE_TRACE"] == "1"
    }

    static func loopPlan(
        isAppActive: Bool
    ) -> ResourceMonitoringPlan {
        ResourceMonitoringPlan(
            refreshIntervalSeconds: refreshIntervalSeconds(
                isAppActive: isAppActive
            ),
            sampleImmediately: isAppActive
        )
    }
}
