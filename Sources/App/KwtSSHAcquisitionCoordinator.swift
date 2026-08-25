import Foundation
import GhosthubTransport

struct KwtSSHDestinationRequest: Hashable, Sendable {
    let destination: String
    let host: SSHHostInfo

    init(destination: String, host: SSHHostInfo) {
        self.destination = destination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.host = host
    }
}

/// Shares SSH acquisition across windows in two stages: one kwt route
/// resolution per destination, then one pooled lease per route identity.
///
/// Every new ownership boundary resolves again, so a configuration change
/// surfaces as `ssh_configuration_changed` before a caller joins a route;
/// only concurrent resolutions of one destination are coalesced.
actor KwtSSHAcquisitionCoordinator {
    typealias Resolver = @Sendable (KwtSSHDestinationRequest) async throws
        -> KwtSSHRouteSnapshot
    typealias PromptHandler = @Sendable (
        _ route: KwtSSHRouteSnapshot,
        _ prompt: KwtSSHLeasePrompt
    ) async throws -> String

    static let shared = KwtSSHAcquisitionCoordinator()

    private struct Resolution {
        let id: UUID
        let task: Task<KwtSSHRouteSnapshot, Error>
        var subscribers: Set<UUID>
    }

    private struct Subscriber {
        let request: KwtSSHDestinationRequest
        let canPresentPrompts: Bool
        let prompt: PromptHandler
        let order: UInt64
        var routeIdentity: String?
    }

    private let resolve: Resolver
    private let pool: KwtSSHConnectionPool
    private var resolutions: [KwtSSHDestinationRequest: Resolution] = [:]
    private var subscribers: [UUID: Subscriber] = [:]
    private var nextOrder: UInt64 = 0

    init(
        resolve: @escaping Resolver = { request in
            try await BlockingTask.runThrowing(priority: .userInitiated) {
                try KwtSSHRouteClient().resolve(request.host)
            }
        },
        pool: KwtSSHConnectionPool = .shared
    ) {
        self.resolve = resolve
        self.pool = pool
    }

    func acquire(
        request: KwtSSHDestinationRequest,
        subscriberID: UUID,
        canPresentPrompts: Bool,
        prompt: @escaping PromptHandler
    ) async throws -> KwtSSHConnection {
        nextOrder &+= 1
        subscribers[subscriberID] = Subscriber(
            request: request,
            canPresentPrompts: canPresentPrompts,
            prompt: prompt,
            order: nextOrder,
            routeIdentity: nil
        )

        return try await withTaskCancellationHandler {
            do {
                let route = try await resolvedRoute(
                    request: request,
                    subscriberID: subscriberID
                )
                guard subscribers[subscriberID] != nil else {
                    throw CancellationError()
                }
                let connection = try await pool.acquire(
                    route: route,
                    subscriberID: subscriberID,
                    hostKeyPolicy: canPresentPrompts ? .review : .strict,
                    prompt: { [weak self] leasePrompt in
                        guard let self else { throw CancellationError() }
                        return try await answerPrompt(
                            route: route,
                            prompt: leasePrompt
                        )
                    }
                )
                subscribers.removeValue(forKey: subscriberID)
                return connection
            } catch {
                await cancel(
                    request: request,
                    subscriberID: subscriberID
                )
                throw error
            }
        } onCancel: { [weak self] in
            Task {
                await self?.cancel(
                    request: request,
                    subscriberID: subscriberID
                )
            }
        }
    }

    func cancel(
        request: KwtSSHDestinationRequest,
        subscriberID: UUID
    ) async {
        let routeIdentity = subscribers.removeValue(
            forKey: subscriberID
        )?.routeIdentity
        if var resolution = resolutions[request] {
            resolution.subscribers.remove(subscriberID)
            if resolution.subscribers.isEmpty {
                resolutions.removeValue(forKey: request)
                resolution.task.cancel()
            } else {
                resolutions[request] = resolution
            }
        }
        if let routeIdentity {
            await pool.cancelAcquisition(
                routeIdentity: routeIdentity,
                subscriberID: subscriberID
            )
        }
    }

    private func resolvedRoute(
        request: KwtSSHDestinationRequest,
        subscriberID: UUID
    ) async throws -> KwtSSHRouteSnapshot {
        let resolution: Resolution
        if var existing = resolutions[request] {
            existing.subscribers.insert(subscriberID)
            resolutions[request] = existing
            resolution = existing
        } else {
            let id = UUID()
            let task = Task { try await resolve(request) }
            resolution = Resolution(
                id: id,
                task: task,
                subscribers: [subscriberID]
            )
            resolutions[request] = resolution
        }
        defer { finishResolution(request: request, id: resolution.id) }
        let route = try await resolution.task.value
        if let current = resolutions[request], current.id == resolution.id {
            for subscriberID in current.subscribers {
                subscribers[subscriberID]?.routeIdentity = route.routeIdentity
            }
        }
        return route
    }

    private func finishResolution(
        request: KwtSSHDestinationRequest,
        id: UUID
    ) {
        guard resolutions[request]?.id == id else { return }
        resolutions.removeValue(forKey: request)
    }

    private func answerPrompt(
        route: KwtSSHRouteSnapshot,
        prompt: KwtSSHLeasePrompt
    ) async throws -> String {
        var attempted: Set<UUID> = []
        while true {
            guard let candidate = subscribers
                .filter({ id, subscriber in
                    !attempted.contains(id)
                        && subscriber.canPresentPrompts
                        && subscriber.routeIdentity == route.routeIdentity
                })
                .min(by: { $0.value.order < $1.value.order })
            else {
                throw KwtSSHLeaseError.operationFailed(
                    code: "ssh_interaction_required",
                    message: "SSH authentication requires an active window.",
                    retryable: false
                )
            }
            attempted.insert(candidate.key)
            do {
                let response = try await candidate.value.prompt(route, prompt)
                guard subscribers[candidate.key]?.routeIdentity
                    == route.routeIdentity else { continue }
                return response
            } catch let error as KwtSSHLeaseError
                where error.code == "ssh_prompt_timed_out" {
                throw error
            } catch {
                await cancel(
                    request: candidate.value.request,
                    subscriberID: candidate.key
                )
            }
        }
    }
}
