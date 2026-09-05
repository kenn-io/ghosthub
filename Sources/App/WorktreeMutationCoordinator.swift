@preconcurrency import Combine
import Foundation
import GhosthubTransport
import GhosthubUI
import GhosthubWorkspace

@MainActor
final class WorktreeMutationCoordinator {
    struct Scope: Hashable, Sendable {
        let hostID: UUID
        let projectIdentity: String
    }

    struct ProjectRegistryHost: Hashable, Sendable {
        let target: CommandHost
    }

    struct ProtectedEndpoint: Hashable, Sendable {
        let worktreeName: String
        let worktreeIdentity: KwtWorktreeIdentity
        let selection: WorkspaceTmuxSessionSelection?
    }

    typealias RemovalTombstone = KwtWorktreeIdentity

    enum Phase: Sendable {
        case began
        case willRemove
        case quarantined
        case ended
        case registered
    }

    struct Event: Sendable {
        let phase: Phase
        let scope: Scope
        let removalTombstones: Set<RemovalTombstone>
        let removalPresentationTargets: Set<WorkspaceTmuxSessionSelection>
        /// Endpoints the failed removal's recovery refresh confirmed for
        /// the surviving target; `nil` when no authoritative refresh
        /// reconciled the failure.
        let reconciledRestorationTargets: Set<WorkspaceTmuxSessionSelection>?
        let requiresWorkspaceReestablishment: Bool
        let removesProject: Bool
        let allowsRemovalRestoration: Bool
        /// The project's root path for project removal and registration,
        /// which identifies it even under a legacy-empty repository identity.
        var projectPath: String?
    }

    struct QuarantinedProjectRemoval: Equatable, Sendable {
        let projectPath: String
        let host: CommandHost
    }

    static let shared = WorktreeMutationCoordinator()

    private var activeScopes: Set<Scope> = []
    private var activeProjectRegistryHosts: Set<ProjectRegistryHost> = []
    private var projectRemovalRegistryHostsByScope:
        [Scope: ProjectRegistryHost] = [:]
    private var pendingRemovalsByScope: [Scope: Set<RemovalTombstone>] = [:]
    private var quarantinedProjectRemovalsByScope:
        [Scope: QuarantinedProjectRemoval] = [:]
    private var protectedEndpointsByParticipant:
        [UUID: [Scope: Set<ProtectedEndpoint>]] = [:]
    private var retiredProtectedEndpointsByScope:
        [Scope: Set<ProtectedEndpoint>] = [:]
    private let eventSubject = PassthroughSubject<Event, Never>()

    private struct ProtectedSelectionKey: Hashable {
        let hostID: UUID
        let name: String
        let socketName: String?
        let tmuxAttachMode: TmuxAttachMode?

        init(_ selection: WorkspaceTmuxSessionSelection) {
            hostID = selection.hostID
            name = selection.name
            socketName = selection.socketName
            tmuxAttachMode = selection.tmuxAttachMode
        }
    }

    var events: AnyPublisher<Event, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    var scopes: Set<Scope> {
        activeScopes
    }

    var pendingRemovals: [Scope: Set<RemovalTombstone>] {
        pendingRemovalsByScope
    }

    var quarantinedProjectRemovals: [Scope: QuarantinedProjectRemoval] {
        quarantinedProjectRemovalsByScope
    }

    func replaceProtectedEndpoints(
        _ endpoints: [Scope: Set<ProtectedEndpoint>],
        for participantID: UUID
    ) {
        for (scope, previous) in
            protectedEndpointsByParticipant[participantID] ?? [:] {
            let superseded = previous.subtracting(endpoints[scope] ?? [])
            retiredProtectedEndpointsByScope[scope, default: []]
                .formUnion(superseded)
        }
        for (scope, replacements) in endpoints {
            let resolvedIdentities = Set(replacements.compactMap { endpoint in
                endpoint.selection == nil ? nil : endpoint.worktreeIdentity
            })
            let resolvedSelections = Set(replacements.compactMap {
                $0.selection.map(ProtectedSelectionKey.init)
            })
            guard let retired = retiredProtectedEndpointsByScope[scope]
            else { continue }
            let remaining = retired.filter { endpoint in
                guard let selection = endpoint.selection else {
                    return !resolvedIdentities.contains(
                        endpoint.worktreeIdentity
                    )
                }
                return !resolvedSelections.contains(
                    ProtectedSelectionKey(selection)
                )
            }
            if remaining.isEmpty {
                retiredProtectedEndpointsByScope.removeValue(forKey: scope)
            } else {
                retiredProtectedEndpointsByScope[scope] = Set(remaining)
            }
        }
        protectedEndpointsByParticipant[participantID] = endpoints
    }

    func retireProtectedEndpoints(for participantID: UUID) {
        guard let endpoints = protectedEndpointsByParticipant.removeValue(
            forKey: participantID
        ) else { return }
        for (scope, values) in endpoints {
            retiredProtectedEndpointsByScope[scope, default: []]
                .formUnion(values)
        }
    }

    func confirmProtectedEndpointAbsent(
        _ selection: WorkspaceTmuxSessionSelection,
        in scope: Scope
    ) {
        guard let endpoints = retiredProtectedEndpointsByScope[scope]
        else { return }
        let remaining = Set(endpoints.filter { endpoint in
            endpoint.selection != selection
        })
        if remaining.isEmpty {
            retiredProtectedEndpointsByScope.removeValue(forKey: scope)
        } else {
            retiredProtectedEndpointsByScope[scope] = remaining
        }
    }

    func reconcileRetiredProtectedEndpoints(
        after inventory: KwtHostInventory,
        hostID: UUID
    ) {
        guard inventory.projectsWarning == nil else { return }
        let scopes = retiredProtectedEndpointsByScope.keys.filter {
            $0.hostID == hostID
        }
        for scope in scopes {
            guard let project = inventory.projects.first(where: {
                $0.project.repository == scope.projectIdentity
            }) else {
                retiredProtectedEndpointsByScope.removeValue(forKey: scope)
                continue
            }
            guard project.warning == nil,
                  let retired = retiredProtectedEndpointsByScope[scope]
            else { continue }
            let remaining = retired.filter { endpoint in
                project.worktrees.contains { worktree in
                    endpoint.worktreeIdentity.matches(
                        path: worktree.path,
                        generation: worktree.generation
                    )
                }
            }
            if remaining.isEmpty {
                retiredProtectedEndpointsByScope.removeValue(forKey: scope)
            } else {
                retiredProtectedEndpointsByScope[scope] = Set(remaining)
            }
        }
    }

    func protectedEndpoints(in scope: Scope) -> Set<ProtectedEndpoint> {
        protectedEndpointsByParticipant.values.reduce(
            into: retiredProtectedEndpointsByScope[scope] ?? []
        ) {
            $0.formUnion($1[scope] ?? [])
        }
    }

    func acquire(
        hostID: UUID,
        projectIdentity: String
    ) -> Bool {
        let scope = Scope(
            hostID: hostID,
            projectIdentity: projectIdentity
        )
        let inserted = activeScopes.insert(scope).inserted
        if inserted {
            eventSubject.send(
                Event(
                    phase: .began,
                    scope: scope,
                    removalTombstones: [],
                    removalPresentationTargets: [],
                    reconciledRestorationTargets: nil,
                    requiresWorkspaceReestablishment: false,
                    removesProject: false,
                    allowsRemovalRestoration: true
                )
            )
        }
        return inserted
    }

    func acquireProjectRegistry(host: ProjectRegistryHost) -> Bool {
        activeProjectRegistryHosts.insert(host).inserted
    }

    func releaseProjectRegistry(host: ProjectRegistryHost) {
        activeProjectRegistryHosts.remove(host)
    }

    func acquireProjectRemoval(
        hostID: UUID,
        projectIdentity: String,
        registryHost: ProjectRegistryHost
    ) -> Bool {
        let scope = Scope(
            hostID: hostID,
            projectIdentity: projectIdentity
        )
        guard !activeProjectRegistryHosts.contains(registryHost),
              !activeScopes.contains(scope)
        else { return false }
        activeProjectRegistryHosts.insert(registryHost)
        projectRemovalRegistryHostsByScope[scope] = registryHost
        activeScopes.insert(scope)
        eventSubject.send(
            Event(
                phase: .began,
                scope: scope,
                removalTombstones: [],
                removalPresentationTargets: [],
                reconciledRestorationTargets: nil,
                requiresWorkspaceReestablishment: false,
                removesProject: false,
                allowsRemovalRestoration: true
            )
        )
        return true
    }

    func release(
        hostID: UUID,
        projectIdentity: String,
        removalTombstones: Set<RemovalTombstone> = [],
        reconciledRestorationTargets:
        Set<WorkspaceTmuxSessionSelection>? = nil,
        requiresWorkspaceReestablishment: Bool = false,
        removesProject: Bool = false,
        allowsRemovalRestoration: Bool = true,
        projectPath: String? = nil
    ) {
        let scope = Scope(
            hostID: hostID,
            projectIdentity: projectIdentity
        )
        if activeScopes.remove(scope) != nil {
            if let registryHost = projectRemovalRegistryHostsByScope
                .removeValue(forKey: scope) {
                activeProjectRegistryHosts.remove(registryHost)
            }
            pendingRemovalsByScope.removeValue(forKey: scope)
            quarantinedProjectRemovalsByScope.removeValue(forKey: scope)
            eventSubject.send(
                Event(
                    phase: .ended,
                    scope: scope,
                    removalTombstones: removalTombstones,
                    removalPresentationTargets: [],
                    reconciledRestorationTargets:
                    reconciledRestorationTargets,
                    requiresWorkspaceReestablishment:
                    requiresWorkspaceReestablishment,
                    removesProject: removesProject,
                    allowsRemovalRestoration: allowsRemovalRestoration,
                    projectPath: projectPath
                )
            )
        }
    }

    func prepareRemoval(
        hostID: UUID,
        projectIdentity: String,
        worktrees: Set<RemovalTombstone>,
        presentationTargets: Set<WorkspaceTmuxSessionSelection>
    ) {
        let scope = Scope(
            hostID: hostID,
            projectIdentity: projectIdentity
        )
        guard activeScopes.contains(scope) else { return }
        pendingRemovalsByScope[scope, default: []].formUnion(worktrees)
        eventSubject.send(
            Event(
                phase: .willRemove,
                scope: scope,
                removalTombstones: worktrees,
                removalPresentationTargets: presentationTargets,
                reconciledRestorationTargets: nil,
                requiresWorkspaceReestablishment: false,
                removesProject: false,
                allowsRemovalRestoration: true
            )
        )
    }

    /// Announces that a project was registered so every scene and the shared
    /// inventory cache forget the removal tombstones for that repository.
    func noteProjectRegistration(
        hostID: UUID,
        projectIdentity: String,
        projectPath: String
    ) {
        eventSubject.send(
            Event(
                phase: .registered,
                scope: Scope(
                    hostID: hostID,
                    projectIdentity: projectIdentity
                ),
                removalTombstones: [],
                removalPresentationTargets: [],
                reconciledRestorationTargets: nil,
                requiresWorkspaceReestablishment: false,
                removesProject: false,
                allowsRemovalRestoration: true,
                projectPath: projectPath
            )
        )
    }

    func quarantineProjectRemoval(
        hostID: UUID,
        projectIdentity: String,
        projectPath: String,
        host: CommandHost
    ) {
        let scope = Scope(
            hostID: hostID,
            projectIdentity: projectIdentity
        )
        guard activeScopes.contains(scope),
              pendingRemovalsByScope[scope] != nil
        else { return }
        quarantinedProjectRemovalsByScope[scope] = QuarantinedProjectRemoval(
            projectPath: projectPath,
            host: host
        )
        eventSubject.send(
            Event(
                phase: .quarantined,
                scope: scope,
                removalTombstones: [],
                removalPresentationTargets: [],
                reconciledRestorationTargets: nil,
                requiresWorkspaceReestablishment: false,
                removesProject: false,
                allowsRemovalRestoration: false
            )
        )
    }
}
