import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

typealias DirectoryBrowserLoader =
    (HostSummary, String) async -> Result<DirectoryListing, HostProbeError>
typealias DirectoryRegistration =
    (HostSummary, String, String?) async -> Result<String, HostProbeError>

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
    let projectContent: (WorkspaceSidebarProject, [NativePopupMenuAction]) -> AnyView
    var routeIdentity: String?

    @State private var expanded = false
    @State private var listing: DirectoryListing?
    @State private var error: String?
    @State private var reload = 0
    @State private var registering = false
    @State private var registered = false
    @State private var showUnregisteredFolders = false

    private var directory: DirectoryWorkspaceSummary? {
        directories.first {
            DirectoryPaths.key($0.path) == DirectoryPaths.key(entry.path)
        }
    }

    private var project: WorkspaceSidebarProject? {
        DirectoryBrowserModel.project(for: entry, in: projects)
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
                projectContent(project, folderActions)
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
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(expanded ? "Collapse" : "Expand") \(project == nil ? "" : "folders in ")\(entry.name)"
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
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 24, height: 28)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(registering || (registered && directory == nil))
                        .accessibilityLabel("Actions for \(entry.name)")
                    }
                }
                if registering {
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
                        if !showUnregisteredFolders {
                            if children.isEmpty {
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
        .task(id: "\(expanded)-\(reload)") {
            guard DirectoryBrowserModel.shouldLoad(
                expanded: expanded, hasListing: listing != nil
            ) else { return }
            error = nil
            let result = await load(host, entry.path)
            guard !Task.isCancelled else { return }
            switch result {
            case let .success(value): listing = value
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
            routeIdentity: listing?.routeIdentity ?? routeIdentity
        ))
    }

    private var folderActions: [NativePopupMenuAction] {
        var actions = [
            NativePopupMenuAction(expanded ? "Hide Folders" : "Browse Folders") {
                expanded.toggle()
            },
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
        guard host.kind != .remote || routeIdentity != nil else {
            error = "Refresh the parent folder before adding this folder."
            return
        }
        registering = true
        error = nil
        Task {
            let result = await action(host, path, routeIdentity)
            registering = false
            switch result {
            case .success: registered = true
            case let .failure(failure): error = failure.displayMessage
            }
        }
    }
}

enum DirectoryBrowserModel {
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
            guard let id = projectIDs[DirectoryPaths.key(child.projectPath ?? child.path)]
            else { continue }
            let projectPath = child.projectPath ?? child.path
            let isPrimary = DirectoryPaths.key(child.path) == DirectoryPaths.key(projectPath)
                || DirectoryPaths.contains(child.path, projectPath)
            if representatives[id] == nil || isPrimary {
                representatives[id] = child.id
            }
        }
        return children.compactMap { child in
            var child = child
            if let id = projectIDs[DirectoryPaths.key(child.projectPath ?? child.path)] {
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
