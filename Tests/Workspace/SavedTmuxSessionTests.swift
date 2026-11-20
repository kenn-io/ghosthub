import Foundation
import GhosthubWorkspace
import Testing

struct SavedTmuxSessionTests {
    @Test func decodesKwtSnapshotEntries() throws {
        let json = """
        {"entries": [
          {"id": "a1", "socket": {"path": "/tmp/tmux-501/default", "name": "default"},
           "session": "api", "saved_at": 1763600000000, "windows": 2, "panes": 3,
           "agents": ["claude", "codex"], "name_taken": false, "worktree": false,
           "state": "pending"},
          {"id": "b2", "socket": {"path": "/tmp/tmux-501/kwt", "name": "kwt"},
           "session": "web", "saved_at": 1763600000000, "windows": 1, "panes": 1,
           "agents": null, "name_taken": true, "worktree": true, "state": "pending"},
          {"id": "c3", "socket": {"path": "/srv/sockets/build"},
           "session": "ci", "saved_at": 1763600000000, "windows": 1, "panes": 1,
           "agents": null, "name_taken": false, "worktree": false, "state": "pending"}
        ]}
        """
        struct Listing: Decodable { var entries: [SavedTmuxSession] }
        let entries = try JSONDecoder().decode(Listing.self, from: Data(json.utf8)).entries

        #expect(entries.map(\.id) == ["a1", "b2", "c3"])
        #expect(entries[0].agents == ["claude", "codex"])
        #expect(entries[0].panes == 3)
        #expect(entries[1].agents.isEmpty)
        #expect(entries[1].nameTaken)
        #expect(entries.filter(\.isOnGhosthubServer).map(\.id) == ["a1", "b2"])
    }

    @Test func cleanRestoreHasNoProblems() throws {
        let json = """
        {"entries": [
          {"id": "a1", "session": "api", "socket": {"path": "/tmp/tmux-501/default", "name": "default"},
           "outcome": "restored",
           "panes": [{"window": 0, "pane": 0, "agent": "claude", "status": "started"},
                     {"window": 0, "pane": 1, "status": "none"}]},
          {"id": "b2", "session": "web", "outcome": "restored", "reason": "already restored"}
        ]}
        """
        let report = try JSONDecoder().decode(TmuxRestoreReport.self, from: Data(json.utf8))
        #expect(report.problems.isEmpty)
    }

    @Test func listsSessionsAndPanesThatDidNotComeBack() throws {
        let json = """
        {"entries": [
          {"id": "a1", "session": "api", "outcome": "partially restored",
           "panes": [{"window": 0, "pane": 0, "agent": "claude", "status": "started"},
                     {"window": 1, "pane": 2, "agent": "codex", "status": "none",
                      "note": "conversation not found"}]},
          {"id": "b2", "session": "web", "outcome": "skipped", "reason": "name in use"},
          {"id": "c3", "outcome": "not found"}
        ]}
        """
        let report = try JSONDecoder().decode(TmuxRestoreReport.self, from: Data(json.utf8))
        #expect(report.problems == [
            "api: partially restored",
            "api, window 1 pane 2: codex not started (conversation not found)",
            "web: skipped (name in use)",
            "c3: not found",
        ])
    }
}
