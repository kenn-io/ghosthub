import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

typealias DirectoryBrowserLoader =
    (HostSummary, String) async -> Result<DirectoryListing, HostProbeError>
typealias DirectoryRegistration =
    (HostSummary, String, String?) async -> Result<String, HostProbeError>
typealias DirectoryRemoval =
    (DirectoryRemovalRequest) async -> Result<String, HostProbeError>
typealias DirectoryRemovalPreparation =
    (HostSummary, DirectoryWorkspaceSummary) async -> Result<
        DirectoryRemovalRequest,
        HostProbeError
    >

/// On-demand folder navigation. Only the menu actions may register a folder.
struct DirectoryBrowserRow: View {
    let host: HostSummary
    let entry: DirectoryEntry
    let directories: [DirectoryWorkspaceSummary]
    let projects: [WorkspaceSidebarProject]
    let load: DirectoryBrowserLoader
    let registerDirectory: DirectoryRegistration?
    let registerProject: DirectoryRegistration?
    let directoryContent: (DirectoryWorkspaceSummary) -> AnyView
    let directoryActions: (DirectoryWorkspaceSummary) -> AnyView
    let projectContent: (WorkspaceSidebarProject, [NativePopupMenuAction], Binding<Bool>) -> AnyView
    let projectExpansion: (UUID) -> Binding<Bool>
    var routeIdentity: String?
    var unregisterDirectory: DirectoryRemoval?
    var prepareDirectoryRemoval: DirectoryRemovalPreparation?

    @State private var folderExpanded = false
    @State private var listing: DirectoryListing?
    @State private var error: String?
    @State private var reload = 0
    @State private var registering = false
    @State private var registered = false
    @State private var showUnregisteredFolders = false
    @State private var removal: DirectoryRemovalRequest?
    @State private var preparingRemoval = false
    @State private var removing = false

    private var loading: Bool {
        expanded && listing == nil && error == nil
            && (project == nil || showUnregisteredFolders || reload > 0)
    }

    private var directory: DirectoryWorkspaceSummary? {
        directories.first {
            DirectoryPaths.key($0.path) == DirectoryPaths.key(entry.path)
        }
    }

    private var project: WorkspaceSidebarProject? {
        DirectoryBrowserModel.project(for: entry, in: projects)
    }

    private var expansion: Binding<Bool> {
        if let project, entry.presentsProject {
            return projectExpansion(project.project.id)
        }
        return $folderExpanded
    }

    private var expanded: Bool {
        get { expansion.wrappedValue }
        nonmutating set { expansion.wrappedValue = newValue }
    }

    private var containsRegistrations: Bool {
        DirectoryBrowserModel.containsRegistrations(
            beneath: entry.path, directories: directories, projects: projects
        )
    }

    private var registrationDescription: String {
        if project != nil {
            return "Registered project"
        }
        return containsRegistrations ? "Contains registered projects or directories" : "Not registered"
    }

    private var childProjects: [WorkspaceSidebarProject] {
        guard let id = project?.id else { return projects }
        return projects.filter { $0.id != id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let project, entry.presentsProject {
                projectContent(project, folderActions, expansion)
            }
            Group {
                if project == nil || !entry.presentsProject || directory != nil {
                    HStack(spacing: 2) {
                        Button {
                            expanded.toggle()
                        } label: {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .frame(width: 18, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(expanded ? "Collapse" : "Expand") \(entry.name)"
                        )
                        if let directory {
                            directoryContent(directory)
                        } else {
                            Button {
                                expanded.toggle()
                            } label: {
                                Label(
                                    entry.name,
                                    systemImage: entry.projectPath == nil ? "folder" : "folder.badge.gearshape"
                                )
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(project != nil || containsRegistrations ? .primary :
                                .secondary)
                            .help(
                                "\(entry.path)\n\(registrationDescription)"
                            )
                            .accessibilityLabel(
                                "\(entry.name), \(registrationDescription)"
                            )
                        }
                        Menu {
                            if directory == nil {
                                if project == nil, entry.projectPath != nil, let registerProject {
                                    Button("Add Project") {
                                        register(
                                            using: registerProject,
                                            path: entry.projectPath ?? entry.path
                                        )
                                    }
                                }
                                if let registerDirectory {
                                    Button("Add Directory") {
                                        register(using: registerDirectory, path: entry.path)
                                    }
                                }
                                Divider()
                            }
                            Button(showUnregisteredFolders ? "Hide Unregistered Folders" :
                                "Show Unregistered Folders") {
                                    showUnregisteredFolders.toggle()
                                }
                            Button("Refresh Folders") {
                                listing = nil
                                expanded = true
                                reload += 1
                            }
                            if let directory {
                                directoryActions(directory)
                                if unregisterDirectory != nil, let prepareDirectoryRemoval {
                                    Divider()
                                    Button("Remove Directory…", role: .destructive) {
                                        preparingRemoval = true
                                        error = nil
                                        Task {
                                            let result = await prepareDirectoryRemoval(
                                                host,
                                                directory
                                            )
                                            preparingRemoval = false
                                            switch result {
                                            case let .success(request): removal = request
                                            case let .failure(failure): error = failure
                                                .displayMessage
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 24, height: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(registering || preparingRemoval || removing ||
                            (registered && directory == nil))
                        .accessibilityLabel("Actions for \(entry.name)")
                    }
                }
                if preparingRemoval {
                    Text("Checking directory…").font(.caption).foregroundStyle(.secondary)
                } else if removing {
                    Text("Removing registration…").font(.caption).foregroundStyle(.secondary)
                } else if registering {
                    Text("Registering…").font(.caption).foregroundStyle(.secondary)
                } else if registered, directory == nil {
                    Text("Added. Updating the sidebar…").font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 1) {
                        let children = DirectoryBrowserModel.children(
                            of: listing?.path ?? entry.path,
                            entries: listing?.entries ?? [],
                            directories: directories, projects: childProjects,
                            showUnregisteredFolders: showUnregisteredFolders
                        )
                        ForEach(children) { child in
                            childRow(child)
                        }
                        if loading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Loading projects…").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Loading projects…")
                        } else if !showUnregisteredFolders {
                            if children.isEmpty, project == nil {
                                Text("No registered child folders").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let listing {
                            if children.isEmpty {
                                Text("No visible child folders").font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if listing.truncated {
                                Text("Large folder: only the first 1,000 entries were inspected.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else if error == nil {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.leading, 18)
                }
            }
        }
        .onChange(of: directory?.id) { _, _ in registered = false }
        .onChange(of: project?.id) { _, _ in registered = false }
        .onChange(of: routeIdentity) { _, _ in
            listing = nil
            error = nil
            reload += 1
        }
        .alert("Remove Directory?", isPresented: Binding(
            get: { removal != nil },
            set: {
                if !$0 {
                    removal = nil
                }
            }
        ), presenting: removal) { request in
            Button("Remove Directory", role: .destructive) {
                guard let unregisterDirectory else { return }
                removing = true
                error = nil
                Task {
                    let result = await unregisterDirectory(request)
                    removing = false
                    if case let .failure(failure) = result {
                        error = failure.displayMessage
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(
                "Remove “\(request.directory.name)” (\(request.directory.path)) on \(request.confirmedHost.name) from registered directories? Files, nested project and directory registrations, and running sessions are preserved."
            )
        }
        .task(id: "\(expanded)-\(showUnregisteredFolders)-\(reload)") {
            guard project == nil || showUnregisteredFolders || reload > 0,
                  DirectoryBrowserModel.shouldLoad(
                      expanded: expanded, hasListing: listing != nil
                  ) else { return }
            error = nil
            let result = await load(host, entry.path)
            guard !Task.isCancelled else { return }
            switch result {
            case let .success(value):
                do {
                    _ = try DirectoryBrowserModel.registrationRoute(
                        parentRoute: routeIdentity, listing: value, remote: host.kind == .remote
                    )
                    listing = value
                } catch let failure as HostProbeError {
                    error = failure.displayMessage
                } catch {
                    self.error = error.localizedDescription
                }
            case let .failure(failure): error = failure.displayMessage
            }
        }
    }

    private func childRow(_ child: DirectoryEntry) -> AnyView {
        AnyView(DirectoryBrowserRow(
            host: host, entry: child, directories: directories, projects: childProjects,
            load: load, registerDirectory: registerDirectory, registerProject: registerProject,
            directoryContent: directoryContent, directoryActions: directoryActions,
            projectContent: projectContent,
            projectExpansion: projectExpansion,
            routeIdentity: listing?.routeIdentity ?? routeIdentity,
            unregisterDirectory: unregisterDirectory,
            prepareDirectoryRemoval: prepareDirectoryRemoval
        ))
    }

    private var folderActions: [NativePopupMenuAction] {
        var actions = [
            NativePopupMenuAction(
                showUnregisteredFolders ? "Hide Unregistered Folders" : "Show Unregistered Folders"
            ) {
                showUnregisteredFolders.toggle()
                expanded = true
            },
            NativePopupMenuAction("Refresh Folders") {
                listing = nil
                expanded = true
                reload += 1
            },
        ]
        if directory == nil, let registerDirectory {
            actions.append(NativePopupMenuAction(
                "Add Directory", isEnabled: !registering && !registered
            ) {
                register(using: registerDirectory, path: entry.path)
            })
        }
        return actions
    }

    private func register(using action: @escaping DirectoryRegistration, path: String) {
        guard !registering else { return }
        let registrationRoute: String?
        do {
            registrationRoute = try DirectoryBrowserModel.registrationRoute(
                parentRoute: routeIdentity, listing: listing, remote: host.kind == .remote
            )
        } catch let failure as HostProbeError {
            error = failure.displayMessage
            return
        } catch {
            self.error = error.localizedDescription
            return
        }
        registering = true
        error = nil
        Task {
            let result = await action(host, path, registrationRoute)
            registering = false
            switch result {
            case .success: registered = true
            case let .failure(failure): error = failure.displayMessage
            }
        }
    }
}

enum DirectoryBrowserModel {
    /// A child's path and project mapping came from its parent. Its own lookup
    /// cannot transfer that registration authority to another SSH destination.
    static func registrationRoute(
        parentRoute: String?, listing: DirectoryListing?, remote: Bool
    ) throws -> String? {
        guard remote else { return nil }
        if let listing {
            guard let route = listing.routeIdentity,
                  parentRoute == nil || parentRoute == route else {
                throw HostProbeError
                    .message("The host connection changed. Refresh the parent folder.")
            }
        }
        guard let route = parentRoute ?? listing?.routeIdentity else {
            throw HostProbeError.message("Refresh Folders before adding this folder.")
        }
        return route
    }

    static func roots(
        _ directories: [DirectoryWorkspaceSummary],
        projects: [WorkspaceSidebarProject]
    ) -> [DirectoryEntry] {
        let entries = projects.map {
            DirectoryEntry(name: $0.project.name, path: $0.project.rootPath)
        } + directories.map { DirectoryEntry(name: $0.name, path: $0.path) }
        var seen = Set<Data>()
        return entries.filter { entry in
            seen.insert(DirectoryPaths.key(entry.path)).inserted
                && !entries.contains { DirectoryPaths.contains($0.path, entry.path) }
        }
    }

    static func containsRegistrations(
        beneath path: String,
        directories: [DirectoryWorkspaceSummary],
        projects: [WorkspaceSidebarProject]
    ) -> Bool {
        projects.contains { DirectoryPaths.contains(path, $0.project.rootPath) }
            || directories.contains { DirectoryPaths.contains(path, $0.path) }
    }

    static func shouldLoad(
        expanded: Bool, hasListing: Bool
    ) -> Bool {
        expanded && !hasListing
    }

    /// Merge known registrations into the visible filesystem level so missing,
    /// hidden, or truncated entries do not make registered projects unreachable.
    static func children(
        of parent: String,
        entries: [DirectoryEntry],
        directories: [DirectoryWorkspaceSummary],
        projects: [WorkspaceSidebarProject],
        showUnregisteredFolders: Bool = true
    ) -> [DirectoryEntry] {
        var children = entries
        let parent = DirectoryPaths.normalized(parent)
        var childPaths = Set(entries.map { DirectoryPaths.key($0.path) })
        var registeredChildPaths = Set<Data>()
        var projectIDs: [Data: UUID] = [:]
        for project in projects {
            let path = DirectoryPaths.key(project.project.rootPath)
            if projectIDs[path] == nil {
                projectIDs[path] = project.id
            }
        }
        func projectPath(for entry: DirectoryEntry) -> String {
            // Current registration wins over a cached linked-checkout mapping.
            if projectIDs[DirectoryPaths.key(entry.path)] != nil {
                return entry.path
            }
            return entry.projectPath ?? entry.path
        }
        for path in directories.map(\.path) + projects.map(\.project.rootPath) {
            guard DirectoryPaths.contains(parent, path) else { continue }
            let relative = DirectoryPaths.normalized(path).utf8
                .dropFirst(parent == "/" ? 1 : parent.utf8.count + 1)
            guard let bytes = relative.split(separator: 0x2F).first else { continue }
            let name = String(decoding: bytes, as: UTF8.self)
            let childPath = (parent == "/" ? "" : parent) + "/" + name
            registeredChildPaths.insert(DirectoryPaths.key(childPath))
            guard childPaths.insert(DirectoryPaths.key(childPath)).inserted else { continue }
            children.append(DirectoryEntry(name: String(name), path: childPath))
        }
        children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Deduplicate project presentation, never a folder with its own
        // registrations. Prefer the primary checkout or its container.
        var representatives: [UUID: Data] = [:]
        for child in children {
            let projectPath = projectPath(for: child)
            guard let id = projectIDs[DirectoryPaths.key(projectPath)]
            else { continue }
            let isPrimary = DirectoryPaths.key(child.path) == DirectoryPaths.key(projectPath)
                || DirectoryPaths.contains(child.path, projectPath)
            if representatives[id] == nil || isPrimary {
                representatives[id] = child.id
            }
        }
        return children.compactMap { child in
            var child = child
            if let id = projectIDs[DirectoryPaths.key(projectPath(for: child))] {
                child.presentsProject = representatives[id] == child.id
            } else {
                child.presentsProject = false
            }
            return showUnregisteredFolders || child.presentsProject
                || registeredChildPaths.contains(DirectoryPaths.key(child.path)) ? child : nil
        }
    }

    static func project(
        for entry: DirectoryEntry, in projects: [WorkspaceSidebarProject]
    ) -> WorkspaceSidebarProject? {
        projects.first {
            DirectoryPaths.key($0.project.rootPath) == DirectoryPaths.key(entry.path)
        } ?? projects.first {
            DirectoryPaths.key($0.project.rootPath)
                == DirectoryPaths.key(entry.projectPath ?? entry.path)
        }
    }

    static func roots(
        _ directories: [DirectoryWorkspaceSummary]
    ) -> [DirectoryWorkspaceSummary] {
        directories.filter { directory in
            !directories.contains {
                $0.hostID == directory.hostID
                    && DirectoryPaths.contains($0.path, directory.path)
            }
        }
    }
}
