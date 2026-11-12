import Foundation
import GhosthubTransport
import GhosthubWorkspace

/// Rex has no client that runs inside a terminal, so Ghosthub uses its
/// pinned kwt: `kwt rex ls --json` lists the terminal blocks on the host
/// account's Rex server and `kwt rex attach BLOCK_ID` shows one. Neither
/// starts a Rex server.
public enum RexInventory {
    public static let marker = "GHOSTHUB_REX_JSON"
    public static let pathMarker = "GHOSTHUB_KWT_PATH"

    /// `kwtPrelude` sets `ghosthub_kwt_path` to the host's pinned kwt, or
    /// exits 127 when there is none.
    public static func executableCommand(kwtPrelude: String) -> String {
        kwtPrelude
            + "[ -x \"$ghosthub_kwt_path\" ] || exit 127; "
            + "printf '%s\\n%s\\n' '\(pathMarker)' \"$ghosthub_kwt_path\""
    }

    public static func command(kwtPrelude: String) -> String {
        kwtPrelude
            + "[ -x \"$ghosthub_kwt_path\" ] || exit 127; "
            + "printf '%s\\n' '\(marker)'; "
            + "exec \"$ghosthub_kwt_path\" rex ls --json"
    }

    public static func parse(
        status: Int32,
        stdout: String,
        stderr: String
    ) -> BackendTerminalDiscoveryResult {
        if status == 127 {
            return .unavailable
        }
        guard status == 0 else {
            return .failure(.commandFailed(.rex, status: status, stderr: stderr))
        }
        guard let payload = MarkedJSON.payload(stdout, after: marker) else {
            return .failure(.missingMarker(.rex))
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: payload) else {
            return .failure(.malformedJSON(.rex))
        }
        switch listing.status {
        case "not_installed", "not_running":
            return .unavailable
        case "running":
            break
        default:
            return .failure(.malformedJSON(.rex))
        }
        var blocks = Set<String>()
        for terminal in listing.terminals {
            guard isBlockID(terminal.blockID), blocks.insert(terminal.blockID).inserted else {
                return .failure(.malformedJSON(.rex))
            }
        }
        return .available(summaries(listing.terminals))
    }

    /// Panes in one Rex window often share a name, such as `zsh ~`, so the
    /// detail places each one: its session, its window when the session has
    /// several, and its pane number when the window has several.
    private static func summaries(_ terminals: [Terminal]) -> [BackendTerminalSummary] {
        let windowsBySession = Dictionary(grouping: terminals, by: \.sessionKey)
            .mapValues { Set($0.map(\.windowKey)).count }
        let panesByWindow = Dictionary(grouping: terminals, by: \.windowKey)
            .mapValues(\.count)
        var paneNumbers: [String: Int] = [:]
        return terminals.map { terminal in
            paneNumbers[terminal.windowKey, default: 0] += 1
            var place = [terminal.sessionLabel].compactMap(nonBlank)
            if windowsBySession[terminal.sessionKey, default: 0] > 1 {
                place.append(windowName(terminal))
            }
            if panesByWindow[terminal.windowKey, default: 0] > 1 {
                place.append("pane \(paneNumbers[terminal.windowKey, default: 0])")
            }
            return BackendTerminalSummary(
                kind: .rex,
                address: terminal.blockID,
                title: [terminal.name, terminal.label].compactMap(nonBlank).first,
                detail: place.isEmpty ? nil : place.joined(separator: " / ")
            )
        }
    }

    /// Rex labels an unnamed window `Window` and an ID fragment; its
    /// position reads better.
    private static func windowName(_ terminal: Terminal) -> String {
        if let label = nonBlank(terminal.windowLabel),
           label.range(of: "^Window [0-9a-f]{8}$", options: .regularExpression) == nil {
            return label
        }
        return terminal.windowIndex.map { "window \($0)" } ?? "window"
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Rex block IDs look like `block:01a1c874-d309-72f9-b5e6-8ef31add4481`.
    /// Anything else could be read as a kwt option.
    public static func isBlockID(_ value: String) -> Bool {
        value.range(of: "^block:[0-9A-Za-z-]+$", options: .regularExpression) != nil
    }

    private struct Listing: Decodable {
        var status: String
        var terminals: [Terminal]
    }

    private struct Terminal: Decodable {
        var blockID: String
        var label: String?
        var name: String?
        var sessionID: String?
        var sessionLabel: String?
        var windowID: String?
        var windowLabel: String?
        var windowIndex: Int?

        var sessionKey: String { sessionID ?? "" }
        var windowKey: String { "\(sessionKey) \(windowID ?? "")" }

        enum CodingKeys: String, CodingKey {
            case blockID = "block_id"
            case label
            case name
            case sessionID = "session_id"
            case sessionLabel = "session_label"
            case windowID = "window_id"
            case windowLabel = "window_label"
            case windowIndex = "window_index"
        }
    }
}
