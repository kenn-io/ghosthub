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
        var terminals: [BackendTerminalSummary] = []
        for terminal in listing.terminals {
            guard isBlockID(terminal.blockID), blocks.insert(terminal.blockID).inserted else {
                return .failure(.malformedJSON(.rex))
            }
            let title = [terminal.title, terminal.label]
                .compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let place = [terminal.sessionLabel, terminal.windowLabel]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            terminals.append(BackendTerminalSummary(
                kind: .rex,
                address: terminal.blockID,
                title: title,
                detail: place.isEmpty ? nil : place.joined(separator: " / ")
            ))
        }
        return .available(terminals)
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
        var title: String?
        var sessionLabel: String?
        var windowLabel: String?

        enum CodingKeys: String, CodingKey {
            case blockID = "block_id"
            case label
            case title
            case sessionLabel = "session_label"
            case windowLabel = "window_label"
        }
    }
}
