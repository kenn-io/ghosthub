import GhosthubWorkspace
import SwiftUI

enum NewWorktreeSheetPolicy {
    static func canDismiss(isCreating: Bool) -> Bool {
        !isCreating
    }
}

enum NewWorktreeProjectLabel {
    static func menuTitle(
        project: ProjectSummary,
        host: HostSummary?
    ) -> String {
        "\(project.sidebarTitle) — \(location(project: project, host: host))"
    }

    static func location(
        project: ProjectSummary,
        host: HostSummary?
    ) -> String {
        let hostName: String
        if let host {
            hostName = [host.sidebarTitle, host.sidebarSubtitle]
                .compactMap { $0 }
                .joined(separator: " · ")
        } else {
            hostName = "Unknown host"
        }
        return "\(hostName) · \(project.sidebarSubtitle)"
    }
}

/// Search-first kwt worktree composer. Ghosthub owns the interaction while kwt
/// owns path selection, branch creation, and the resulting tmux session.
struct NewWorktreeSheet: View {
    let projects: [ProjectSummary]
    let hosts: [HostSummary]
    let onCreate: (WorktreeCreateRequest) async throws -> Void
    let onCancel: () -> Void

    @State private var selectedProject: ProjectSummary
    @State private var branchName = ""
    @State private var createsBranch = true
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var isBranchFieldFocused: Bool

    init(
        project: ProjectSummary,
        projects: [ProjectSummary],
        hosts: [HostSummary],
        onCreate: @escaping (WorktreeCreateRequest) async throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        _selectedProject = State(initialValue: project)
        self.projects = projects
        self.hosts = hosts
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    private var normalizedBranchName: String {
        branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        !isCreating && GitBranchName.isValid(normalizedBranchName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            Divider()
            searchField
            Divider()
            resultSection
                .frame(minHeight: 84, maxHeight: 240)
            Divider()
            bottomStrip
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onExitCommand(perform: cancelIfIdle)
        .onAppear { isBranchFieldFocused = true }
    }

    private var titleRow: some View {
        HStack {
            Text("New worktree")
                .font(.headline)
            Spacer()
            Menu {
                ForEach(projects) { project in
                    Button(projectMenuTitle(project)) {
                        selectedProject = project
                    }
                }
            } label: {
                VStack(alignment: .trailing, spacing: 1) {
                    Label(
                        selectedProject.sidebarTitle,
                        systemImage: "folder"
                    )
                    Text(projectLocation(selectedProject))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isCreating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Branch name", text: $branchName)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isBranchFieldFocused)
                .disabled(isCreating)
                .onSubmit(create)
            if isCreating {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var resultSection: some View {
        if normalizedBranchName.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Type a branch name to create a kwt worktree.")
                    .font(.callout)
                Text(
                    "Pull request discovery and import will appear here when kwt exposes that workflow."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        } else {
            Button(action: create) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(
                            systemName: createsBranch
                                ? "plus.circle.fill" : "arrow.right.circle.fill"
                        )
                        .foregroundStyle(createsBranch ? .green : .blue)
                        Text(
                            createsBranch
                                ? "Create branch" : "Check out existing branch"
                        )
                        .fontWeight(.medium)
                        Text("\"\(normalizedBranchName)\"")
                    }
                    .font(.callout)
                    Text("in \(selectedProject.sidebarTitle) with kwt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color.accentColor.opacity(0.14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
        }
    }

    private var bottomStrip: some View {
        HStack(spacing: 10) {
            Picker("Branch action", selection: $createsBranch) {
                Text("Create new branch").tag(true)
                Text("Use existing branch").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            .disabled(isCreating)

            Spacer()
            Button("Cancel", action: cancelIfIdle)
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
            Button(createsBranch ? "Create Branch" : "Create Worktree") {
                create()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func create() {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil
        let request = WorktreeCreateRequest(
            projectID: selectedProject.id,
            branchName: normalizedBranchName,
            createsBranch: createsBranch
        )
        Task {
            do {
                try await onCreate(request)
                onCancel()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }

    private func cancelIfIdle() {
        guard NewWorktreeSheetPolicy.canDismiss(
            isCreating: isCreating
        ) else { return }
        onCancel()
    }

    private func projectMenuTitle(_ project: ProjectSummary) -> String {
        NewWorktreeProjectLabel.menuTitle(
            project: project,
            host: hosts.first { $0.id == project.hostID }
        )
    }

    private func projectLocation(_ project: ProjectSummary) -> String {
        NewWorktreeProjectLabel.location(
            project: project,
            host: hosts.first { $0.id == project.hostID }
        )
    }
}
