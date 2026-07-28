import GhosthubWorkspace
import SwiftUI

enum NewWorktreeSheetPolicy {
    static func canDismiss(isCreating: Bool) -> Bool {
        !isCreating
    }
}

enum NewWorktreeMode: String, CaseIterable, Hashable {
    case branch
    case pullRequest
}

enum PullRequestSelector {
    static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }
        let number = trimmed.hasPrefix("#")
            ? String(trimmed.dropFirst())
            : trimmed
        if !number.isEmpty, number.allSatisfy(\.isNumber) {
            return number
        }
        guard let url = URL(string: trimmed),
              url.host != nil
        else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let pullIndex = components.firstIndex(of: "pull"),
              components.indices.contains(pullIndex + 1),
              components[pullIndex + 1].allSatisfy(\.isNumber)
        else { return nil }
        return trimmed
    }
}

enum PullRequestQuery {
    /// Ranks an exact pull request number ahead of incidental substring hits.
    /// Without this, "32" matches "#132" as readily as "#32" and resolves to
    /// whichever kwt happened to list first.
    static func matches(
        in pullRequests: [PullRequestCandidate],
        query: String
    ) -> [PullRequestCandidate] {
        let tokens = query.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return pullRequests }
        let matched = pullRequests.filter { pullRequest in
            let haystack = [
                "#\(pullRequest.number)",
                pullRequest.title,
                pullRequest.author,
                pullRequest.sourceBranch,
                pullRequest.targetBranch,
            ].joined(separator: " ").lowercased()
            return tokens.allSatisfy(haystack.contains)
        }
        guard let number = requestedNumber(query),
              let exact = matched.firstIndex(where: { $0.number == number })
        else { return matched }
        var ranked = matched
        ranked.insert(ranked.remove(at: exact), at: 0)
        return ranked
    }

    /// The candidate a query implies. A typed number names exactly one pull
    /// request, so it selects that candidate or nothing: settling for one that
    /// merely contains those digits would import #132 for a typed 32. Leaving
    /// the selection empty hands the number to kwt instead, which can resolve
    /// pull requests this list never showed. An exact number still wins when
    /// it is already imported, because that is still the one the user named.
    /// A text query has no such single answer, so prefer an unimported hit.
    static func impliedSelectionID(
        in candidates: [PullRequestCandidate],
        query: String
    ) -> String? {
        if let number = requestedNumber(query) {
            return candidates.first { $0.number == number }?.id
        }
        return candidates.first(where: { !$0.isImported })?.id
            ?? candidates.first?.id
    }

    /// The selector an import submits. A candidate the user can currently see
    /// and pick wins; otherwise the typed query goes to kwt verbatim. Deriving
    /// both the submitted selector and the submit gate from this keeps an
    /// enabled button from importing something other than what it names.
    static func importSelector(
        in candidates: [PullRequestCandidate],
        query: String,
        selectedID: String?
    ) -> String? {
        if let selectedID,
           candidates.contains(where: { $0.id == selectedID }) {
            return selectedID
        }
        return PullRequestSelector.normalized(query)
    }

    private static func requestedNumber(_ query: String) -> Int? {
        PullRequestSelector.normalized(query).flatMap(Int.init)
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

/// Search-first kwt workspace composer. Ghosthub owns the interaction while
/// kwt owns provider access, refs, paths, branch naming, and tmux identity.
struct NewWorktreeSheet: View {
    let projects: [ProjectSummary]
    let hosts: [HostSummary]
    let onCreate: (WorktreeCreateRequest) async throws -> Void
    let onListPullRequests: (UUID) async throws
        -> [PullRequestCandidate]
    let onImportPullRequest:
        (PullRequestImportRequest) async throws -> Void
    let onCancel: () -> Void

    @State private var selectedProject: ProjectSummary
    @State private var selectedMode: NewWorktreeMode
    @State private var query = ""
    @State private var createsBranch = true
    @State private var isWorking = false
    @State private var isLoadingPullRequests = false
    @State private var errorMessage: String?
    @State private var pullRequests: [PullRequestCandidate] = []
    @State private var selectedPullRequestID: String?
    @FocusState private var isSearchFieldFocused: Bool

    init(
        project: ProjectSummary,
        projects: [ProjectSummary],
        hosts: [HostSummary],
        initialMode: NewWorktreeMode = .branch,
        onCreate: @escaping (WorktreeCreateRequest) async throws -> Void,
        onListPullRequests: @escaping (UUID) async throws
            -> [PullRequestCandidate] = { _ in [] },
        onImportPullRequest: @escaping (
            PullRequestImportRequest
        ) async throws -> Void = { _ in },
        onCancel: @escaping () -> Void
    ) {
        _selectedProject = State(initialValue: project)
        _selectedMode = State(initialValue: initialMode)
        self.projects = projects
        self.hosts = hosts
        self.onCreate = onCreate
        self.onListPullRequests = onListPullRequests
        self.onImportPullRequest = onImportPullRequest
        self.onCancel = onCancel
    }

    private var normalizedBranchName: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreateBranch: Bool {
        selectedMode == .branch
            && !isWorking
            && canCreateWorktree(in: selectedProject)
            && GitBranchName.isValid(normalizedBranchName)
    }

    private var selectedPullRequest: PullRequestCandidate? {
        filteredPullRequests.first {
            $0.id == selectedPullRequestID
        }
    }

    private var directPullRequestSelector: String? {
        PullRequestSelector.normalized(query)
    }

    private var pullRequestImportSelector: String? {
        PullRequestQuery.importSelector(
            in: filteredPullRequests,
            query: query,
            selectedID: selectedPullRequestID
        )
    }

    private var canImportPullRequest: Bool {
        selectedMode == .pullRequest
            && !isWorking
            && !isLoadingPullRequests
            && pullRequestImportSelector != nil
            && canImportPullRequest(in: selectedProject)
    }

    private var filteredPullRequests: [PullRequestCandidate] {
        PullRequestQuery.matches(in: pullRequests, query: query)
    }

    private var pullRequestLoadID: String {
        "\(selectedMode.rawValue):\(selectedProject.id.uuidString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            Divider()
            modePicker
            Divider()
            searchField
            Divider()
            resultSection
                .frame(minHeight: 120, maxHeight: 320)
            Divider()
            bottomStrip
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onExitCommand(perform: cancelIfIdle)
        .onAppear {
            ensureProjectSupportsSelectedMode()
            isSearchFieldFocused = true
        }
        .onChange(of: selectedMode) { _, _ in
            query = ""
            errorMessage = nil
            ensureProjectSupportsSelectedMode()
            isSearchFieldFocused = true
        }
        .onChange(of: query) { _, _ in
            guard selectedMode == .pullRequest else { return }
            selectedPullRequestID = PullRequestQuery.impliedSelectionID(
                in: filteredPullRequests,
                query: query
            )
        }
        .task(id: pullRequestLoadID) {
            guard selectedMode == .pullRequest else { return }
            await loadPullRequests()
        }
    }

    private var titleRow: some View {
        HStack {
            Text("New worktree")
                .font(.headline)
            Spacer()
            NativePopupMenuButton(
                groups: [
                    projectsForSelectedMode.map { project in
                        NativePopupMenuAction(projectMenuTitle(project)) {
                            selectedProject = project
                            query = ""
                            errorMessage = nil
                        }
                    },
                ]
            ) {
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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(projectMenuTitle(selectedProject))
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(isWorking)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var modePicker: some View {
        Picker("Workspace source", selection: $selectedMode) {
            Label("Branch", systemImage: "arrow.triangle.branch")
                .tag(NewWorktreeMode.branch)
            Label("Pull Request", systemImage: "arrow.down.doc")
                .tag(NewWorktreeMode.pullRequest)
        }
        .pickerStyle(.segmented)
        .disabled(isWorking)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                selectedMode == .branch
                    ? "Branch name"
                    : "Filter or paste a PR number or URL",
                text: $query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .focused($isSearchFieldFocused)
            .disabled(isWorking)
            .onSubmit(submit)
            if isWorking || isLoadingPullRequests {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var resultSection: some View {
        if selectedMode == .branch {
            branchResults
        } else {
            pullRequestResults
        }
    }

    @ViewBuilder
    private var branchResults: some View {
        if normalizedBranchName.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Create a kwt worktree from a branch.")
                    .font(.callout)
                Text(
                    "kwt chooses the path and reports the exact tmux session."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        } else {
            Button(action: createBranch) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(
                            systemName: createsBranch
                                ? "plus.circle.fill"
                                : "arrow.right.circle.fill"
                        )
                        .foregroundStyle(createsBranch ? .green : .blue)
                        Text(
                            createsBranch
                                ? "Create branch"
                                : "Check out existing branch"
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
            .disabled(!canCreateBranch)
        }

        errorView
    }

    @ViewBuilder
    private var pullRequestResults: some View {
        if isLoadingPullRequests, pullRequests.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading pull requests from kwt…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredPullRequests.isEmpty,
                  let directPullRequestSelector {
            directSelectorRow(directPullRequestSelector)
            errorView
        } else if pullRequests.isEmpty, let errorMessage {
            ContentUnavailableView(
                "Pull Requests Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if filteredPullRequests.isEmpty {
            ContentUnavailableView(
                query.isEmpty
                    ? "No Open Pull Requests"
                    : "No Matching Pull Requests",
                systemImage: "arrow.down.doc",
                description: Text(
                    query.isEmpty
                        ? "kwt found no open pull requests for this project."
                        : "Try a PR number, title, author, or branch."
                )
            )
        } else {
            // A typed number selects nothing unless the list holds that exact
            // pull request, so name the selector that would actually be
            // imported rather than leaving the listed near-misses to imply it.
            if selectedPullRequest == nil, let directPullRequestSelector {
                directSelectorRow(directPullRequestSelector)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredPullRequests) { pullRequest in
                        pullRequestRow(pullRequest)
                    }
                }
                .padding(8)
            }
            errorView
        }
    }

    private func directSelectorRow(_ selector: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Import pull request \(selector)")
                    .font(.callout.weight(.medium))
                Text("kwt will validate this selector for the project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color.accentColor.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .padding(8)
    }

    private func pullRequestRow(
        _ pullRequest: PullRequestCandidate
    ) -> some View {
        let isSelected = selectedPullRequestID == pullRequest.id
        return Button {
            selectedPullRequestID = pullRequest.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("#\(pullRequest.number)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                        Text(pullRequest.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if pullRequest.isDraft {
                            badge("Draft")
                        }
                        if pullRequest.isImported {
                            badge("Imported")
                        }
                    }
                    Text(
                        "\(pullRequest.author) · \(pullRequest.sourceBranch) → \(pullRequest.targetBranch)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.16)
                        : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Pull request \(pullRequest.number), \(pullRequest.title)"
        )
        .accessibilityValue(pullRequest.isImported ? "Imported" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    @ViewBuilder
    private var errorView: some View {
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
            if selectedMode == .branch {
                Picker("Branch action", selection: $createsBranch) {
                    Text("Create new branch").tag(true)
                    Text("Use existing branch").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                .disabled(isWorking)
            } else {
                Text("\(pullRequests.count) open pull requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button("Cancel", action: cancelIfIdle)
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)
            Button(primaryActionTitle, action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var primaryActionTitle: String {
        switch selectedMode {
        case .branch:
            return createsBranch ? "Create Branch" : "Create Worktree"
        case .pullRequest:
            return selectedPullRequest?.isImported == true
                ? "Open Worktree"
                : "Import Pull Request"
        }
    }

    private var canSubmit: Bool {
        switch selectedMode {
        case .branch: canCreateBranch
        case .pullRequest: canImportPullRequest
        }
    }

    private var projectsForSelectedMode: [ProjectSummary] {
        projects.filter {
            switch selectedMode {
            case .branch: canCreateWorktree(in: $0)
            case .pullRequest: canImportPullRequest(in: $0)
            }
        }
    }

    private func submit() {
        switch selectedMode {
        case .branch: createBranch()
        case .pullRequest: importSelectedPullRequest()
        }
    }

    private func createBranch() {
        guard canCreateBranch else { return }
        isWorking = true
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
                isWorking = false
            }
        }
    }

    private func importSelectedPullRequest() {
        guard canImportPullRequest,
              let selector = pullRequestImportSelector
        else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await onImportPullRequest(
                    PullRequestImportRequest(
                        projectID: selectedProject.id,
                        pullRequestID: selector
                    )
                )
                onCancel()
            } catch {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func loadPullRequests() async {
        guard canImportPullRequest(in: selectedProject) else { return }
        isLoadingPullRequests = true
        errorMessage = nil
        do {
            let loaded = try await onListPullRequests(selectedProject.id)
            guard !Task.isCancelled else { return }
            pullRequests = loaded
            // Selecting out of the whole list would ignore a number typed
            // while the list was still loading.
            let candidates = filteredPullRequests
            if !candidates.contains(where: {
                $0.id == selectedPullRequestID
            }) {
                selectedPullRequestID = PullRequestQuery.impliedSelectionID(
                    in: candidates,
                    query: query
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            pullRequests = []
            selectedPullRequestID = nil
            errorMessage = error.localizedDescription
        }
        isLoadingPullRequests = false
    }

    private func ensureProjectSupportsSelectedMode() {
        guard !projectsForSelectedMode.contains(where: {
            $0.id == selectedProject.id
        }), let first = projectsForSelectedMode.first
        else { return }
        selectedProject = first
    }

    private func canCreateWorktree(
        in project: ProjectSummary
    ) -> Bool {
        !project.isSynthesized
            && !project.isStale
            && hosts.first(where: { $0.id == project.hostID })?
            .canCreateWorktree == true
    }

    private func canImportPullRequest(
        in project: ProjectSummary
    ) -> Bool {
        !project.isSynthesized
            && !project.isStale
            && project.scopedKey.lowercased().hasPrefix("github.com/")
            && hosts.first(where: { $0.id == project.hostID })?
            .canImportPullRequest == true
    }

    private func cancelIfIdle() {
        guard NewWorktreeSheetPolicy.canDismiss(
            isCreating: isWorking
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
