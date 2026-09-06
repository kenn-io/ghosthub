import Foundation
import GhosthubWorkspace
import Testing

@Suite("worktree file changes")
struct WorktreeFileChangesTests {
    @Test(
        "semantic states preserve the kwt wire contract",
        arguments: [
            "modified", "added", "deleted", "renamed", "copied",
            "conflicted", "untracked",
        ]
    )
    func semanticStates(rawValue: String) throws {
        let value = try JSONDecoder().decode(
            WorktreeFileState.self,
            from: Data("\"\(rawValue)\"".utf8)
        )

        #expect(value.rawValue == rawValue)
    }

    @Test("unknown semantic states fail closed")
    func unknownSemanticState() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                WorktreeFileState.self,
                from: Data(#""future-state""#.utf8)
            )
        }
    }

    @Test("file paths and rename origins round-trip without normalization")
    func unusualPaths() throws {
        let value = WorktreeFileChange(
            path: "Sources/space tab\tnewline\n雪.swift",
            originalPath: "Sources/old name.swift",
            index: .renamed,
            worktree: .modified
        )

        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(
            WorktreeFileChange.self,
            from: data
        ) == value)
    }

    @Test("changed files sort by resulting path then rename origin")
    func presentationOrder() {
        let files = [
            WorktreeFileChange(
                path: "z.swift",
                originalPath: "a.swift",
                index: .renamed,
                worktree: nil
            ),
            WorktreeFileChange(
                path: "a.swift",
                originalPath: nil,
                index: nil,
                worktree: .modified
            ),
        ]

        #expect(files.sortedForPresentation().map(\.path) == [
            "a.swift", "z.swift",
        ])
    }
}
