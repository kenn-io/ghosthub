import GhosthubWorkspace
import SwiftUI

public enum WorktreeFileChangePresentation {
    public static func label(for state: WorktreeFileState) -> String {
        switch state {
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .conflicted: "Conflict"
        case .untracked: "Untracked"
        }
    }

    public static func symbol(for state: WorktreeFileState) -> String {
        switch state {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .conflicted: "!"
        case .untracked: "?"
        }
    }

    public static func statusCode(
        index: WorktreeFileState?,
        worktree: WorktreeFileState?
    ) -> String {
        if index == .untracked || worktree == .untracked {
            return "??"
        }
        return (index.map(symbol(for:)) ?? " ")
            + (worktree.map(symbol(for:)) ?? " ")
    }

    public static func accessibilityValue(
        for file: WorktreeFileChange
    ) -> String {
        var values = [file.path]
        if let originalPath = file.originalPath {
            let action = file.index == .copied || file.worktree == .copied
                ? "copied"
                : "renamed"
            values.append("\(action) from \(originalPath)")
        }
        if let index = file.index {
            values.append("staged \(label(for: index).lowercased())")
        }
        if let worktree = file.worktree {
            values.append(
                "working tree \(label(for: worktree).lowercased())"
            )
        }
        return values.joined(separator: ", ")
    }
}

public enum WorktreeChangesPresentation {
    public static let filePageSize = 200

    public static func showsLoadingChrome(
        for entry: WorktreeChangesEntry
    ) -> Bool {
        entry.isLoading && !entry.hasSuccessfulValue
    }

    public static func showsActivityIndicator(
        for entry: WorktreeChangesEntry
    ) -> Bool {
        entry.isLoading
    }

    public static func showsRetry(
        for entry: WorktreeChangesEntry,
        canRefresh: Bool
    ) -> Bool {
        canRefresh && !entry.hasSuccessfulValue && entry.errorMessage != nil
    }

    public static func page(
        files: [WorktreeFileChange],
        requestedCount: Int
    ) -> WorktreeChangesPage {
        let visibleCount = min(
            files.count,
            max(filePageSize, requestedCount)
        )
        return WorktreeChangesPage(
            files: Array(files.prefix(visibleCount)),
            remainingCount: files.count - visibleCount,
            nextRequestedCount: min(
                files.count,
                visibleCount + filePageSize
            )
        )
    }

    public static func adjustedRequestedCount(
        _ requestedCount: Int,
        forFileCount fileCount: Int
    ) -> Int {
        max(filePageSize, min(requestedCount, fileCount))
    }
}

public struct WorktreeChangesPage: Equatable, Sendable {
    public let files: [WorktreeFileChange]
    public let remainingCount: Int
    public let nextRequestedCount: Int
}

public struct WorktreeChangesView: View {
    public let entry: WorktreeChangesEntry
    public let onRefresh: (() -> Void)?
    @State private var requestedFileCount =
        WorktreeChangesPresentation.filePageSize

    public init(
        entry: WorktreeChangesEntry,
        onRefresh: (() -> Void)?
    ) {
        self.entry = entry
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Changes")
                    .font(.caption.weight(.semibold))
                if entry.isStale {
                    Text("Stale")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("worktree-changes-stale")
                }
                Spacer(minLength: 4)
                if WorktreeChangesPresentation.showsActivityIndicator(
                    for: entry
                ) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(
                            entry.hasSuccessfulValue
                                ? "Refreshing changed files"
                                : "Loading changed files"
                        )
                        .accessibilityIdentifier("worktree-changes-loading")
                } else if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh changes")
                    .accessibilityLabel("Refresh changes")
                    .accessibilityIdentifier("worktree-changes-refresh")
                }
            }

            if WorktreeChangesPresentation.showsLoadingChrome(for: entry) {
                EmptyView()
            } else if !entry.hasSuccessfulValue,
                      let errorMessage = entry.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if WorktreeChangesPresentation.showsRetry(
                        for: entry,
                        canRefresh: onRefresh != nil
                    ), let onRefresh {
                        Button("Retry", action: onRefresh)
                            .buttonStyle(.link)
                    }
                }
                .accessibilityIdentifier("worktree-changes-first-error")
            } else if entry.hasSuccessfulValue, entry.files.isEmpty {
                Text("No changed files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("worktree-changes-empty")
            } else {
                let page = WorktreeChangesPresentation.page(
                    files: entry.files,
                    requestedCount: requestedFileCount
                )
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(page.files, id: \.path) { file in
                        WorktreeFileChangeRow(file: file)
                    }
                    if page.remainingCount > 0 {
                        let revealCount = min(
                            WorktreeChangesPresentation.filePageSize,
                            page.remainingCount
                        )
                        Button("Show \(revealCount) more") {
                            requestedFileCount = page.nextRequestedCount
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier(
                            "worktree-changes-show-more"
                        )
                    }
                }
                .accessibilityIdentifier("worktree-changes-list")
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(
            cornerRadius: 6
        ))
        .onChange(of: entry.files.count) {
            requestedFileCount =
                WorktreeChangesPresentation.adjustedRequestedCount(
                    requestedFileCount,
                    forFileCount: entry.files.count
                )
        }
    }
}

private struct WorktreeFileChangeRow: View {
    let file: WorktreeFileChange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: WorktreeFileChangePresentation.statusCode(
                index: file.index,
                worktree: file.worktree
            ))
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 18, alignment: .leading)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                if let originalPath = file.originalPath {
                    Text("from \(originalPath)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            WorktreeFileChangePresentation.accessibilityValue(for: file)
        )
    }
}
