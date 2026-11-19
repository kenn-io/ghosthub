import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

typealias DirectoryBrowserLoader =
    (HostSummary, String) async -> Result<DirectoryListing, HostProbeError>
typealias DirectoryRegistration =
    (HostSummary, String) async -> Result<String, HostProbeError>

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
    let projectContent: (WorkspaceSidebarProject) -> AnyView

    @State private var expanded = false
    @State private var listing: DirectoryListing?
    @State private var error: String?
    @State private var reload = 0
    @State private var registering = false
    @State private var registered = false
    @State private var showUnregisteredFolders = false

    private var directory: DirectoryWorkspaceSummary? {
        directories.first {
            DirectoryPaths.normalized($0.path) == DirectoryPaths.normalized(entry.path)
        }
    }

    private var project: WorkspaceSidebarProject? {
        DirectoryBrowserModel.project(for: entry, in: projects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let project, directory == nil {
                projectContent(project)
            } else {
                HStack(spacing: 2) {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .frame(width: 18, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(entry.name)")
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
                        .foregroundStyle(.secondary)
                        .help("\(entry.path)\nNot registered")
                        .accessibilityLabel("\(entry.name), not registered")
                    }
                    Menu {
                        if directory == nil {
                            if entry.projectPath != nil, let registerProject {
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
                if registering {
                    Text("Registering…").font(.caption).foregroundStyle(.secondary)
                } else if registered, directory == nil {
                    Text("Added. Refreshing inventory…").font(.caption).foregroundStyle(.secondary)
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
                            directories: directories, projects: projects,
                            showUnregisteredFolders: showUnregisteredFolders
                        )
                        ForEach(children) { child in
                            childRow(child)
                        }
                        if let listing {
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
            guard expanded, project == nil || directory != nil else { return }
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
            host: host, entry: child, directories: directories, projects: projects,
            load: load, registerDirectory: registerDirectory, registerProject: registerProject,
            directoryContent: directoryContent, directoryActions: directoryActions,
            projectContent: projectContent
        ))
    }

    private func register(using action: @escaping DirectoryRegistration, path: String) {
        guard !registering else { return }
        registering = true
        error = nil
        Task {
            let result = await action(host, path)
            registering = false
            switch result {
            case .success: registered = true
            case let .failure(failure): error = failure.displayMessage
            }
        }
    }
}

enum DirectoryBrowserModel {
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
        for path in directories.map(\.path) + projects.map(\.project.rootPath) {
            guard DirectoryPaths.contains(parent, path) else { continue }
            let relative = DirectoryPaths.normalized(path)
                .dropFirst(parent == "/" ? 1 : parent.count + 1)
            guard let name = relative.split(separator: "/").first else { continue }
            let childPath = (parent == "/" ? "" : parent) + "/" + name
            guard !children.contains(where: { DirectoryPaths.normalized($0.path) == childPath })
            else { continue }
            children.append(DirectoryEntry(name: String(name), path: childPath))
        }
        var seenProjects = Set<UUID>()
        return children.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .filter { child in
                showUnregisteredFolders
                    || project(for: child, in: projects) != nil
                    || (directories.map(\.path) + projects.map(\.project.rootPath)).contains {
                        DirectoryPaths.normalized($0) == DirectoryPaths.normalized(child.path)
                            || DirectoryPaths.contains(child.path, $0)
                    }
            }
            .filter {
                guard let project = project(for: $0, in: projects) else { return true }
                return seenProjects.insert(project.id).inserted
            }
    }

    static func project(
        for entry: DirectoryEntry, in projects: [WorkspaceSidebarProject]
    ) -> WorkspaceSidebarProject? {
        projects.first {
            DirectoryPaths.normalized($0.project.rootPath)
                == DirectoryPaths.normalized(entry.projectPath ?? entry.path)
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
