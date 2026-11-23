import Foundation
import GhosthubTransport
import GhosthubWorkspace

/// Rex has no client that runs inside a terminal, so Ghosthub uses its
/// pinned kwt: `kwt rex ls --json` lists the terminal blocks on the host
/// account's Rex server, which Ghosthub shows as one row per Rex window.
/// `kwt rex control WINDOW_ID` follows a window's layout and
/// `kwt rex attach BLOCK_ID` shows one of its panes. None of them starts a
/// Rex server.
public enum RexInventory {
    public static let marker = "GHOSTHUB_REX_JSON"
    public static let pathMarker = "GHOSTHUB_KWT_PATH"
    /// `kwt rex control` output starts after this line.
    public static let controlMarker = "GHOSTHUB_REX_CONTROL"

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

    /// Opens a shell in a new Rex window, in a new session unless
    /// `sessionID` names one. `label` names the new session, or the window
    /// in `sessionID`.
    public static func newWindowCommand(
        kwtPrelude: String,
        label: String?,
        sessionID: String?,
        cwd: String?
    ) -> String {
        let options = [("--label", label), ("--session", sessionID), ("--cwd", cwd)]
            .compactMap { flag, value in
                value.map { " \(flag) \(shellQuotedCommandArgument($0))" }
            }
            .joined()
        return kwtPrelude
            + "[ -x \"$ghosthub_kwt_path\" ] || exit 127; "
            + "printf '%s\\n' '\(marker)'; "
            + "exec \"$ghosthub_kwt_path\" rex new\(options)"
    }

    /// The new window's ID from `kwt rex new`.
    public static func parseNewWindow(
        status: Int32,
        stdout: String,
        stderr: String
    ) -> Result<String, BackendTerminalCommandError> {
        if status == 127 {
            return .failure(.unavailable(.rex))
        }
        guard status == 0 else {
            return .failure(.commandFailed(.rex, status: status, stderr: stderr))
        }
        guard let payload = MarkedJSON.payload(stdout, after: marker) else {
            return .failure(.missingMarker(.rex))
        }
        guard let created = try? JSONDecoder().decode(Created.self, from: payload),
              isWindowID(created.windowID)
        else {
            return .failure(.malformedJSON(.rex))
        }
        return .success(created.windowID)
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
        var sessionByWindow: [String: String] = [:]
        for terminal in listing.terminals {
            guard isBlockID(terminal.blockID), blocks.insert(terminal.blockID).inserted,
                  let windowID = terminal.windowID, isWindowID(windowID)
            else {
                return .failure(.malformedJSON(.rex))
            }
            // A row opens its window by ID alone, so the ID must name one
            // window on the server.
            let session = sessionByWindow[windowID, default: terminal.sessionKey]
            guard session == terminal.sessionKey else {
                return .failure(.malformedJSON(.rex))
            }
            sessionByWindow[windowID] = session
        }
        return .available(summaries(listing.terminals))
    }

    /// One row per Rex window, in the order Rex lists them.
    private static func summaries(_ terminals: [Terminal]) -> [BackendTerminalSummary] {
        var order: [String] = []
        var panes: [String: [Terminal]] = [:]
        for terminal in terminals {
            let windowID = terminal.windowID ?? ""
            if panes[windowID] == nil {
                order.append(windowID)
            }
            panes[windowID, default: []].append(terminal)
        }
        return order.compactMap { windowID in
            guard let window = panes[windowID], let first = window.first else { return nil }
            let focused = window.first(where: { $0.focused == true }) ?? first
            return windowRow(
                windowID: windowID,
                windowLabel: first.windowLabel,
                sessionLabel: first.sessionLabel,
                focusedPaneNames: [focused.name, focused.label],
                paneCount: window.count
            )
        }
    }

    /// A Rex window's sidebar row. Rex names an unnamed window `Window` and
    /// an ID fragment, so such a window takes the first of its focused
    /// pane's names that is not blank.
    public static func windowRow(
        windowID: String,
        windowLabel: String?,
        sessionLabel: String?,
        focusedPaneNames: [String?],
        paneCount: Int
    ) -> BackendTerminalSummary {
        let label = nonBlank(windowLabel).flatMap {
            $0.range(of: "^Window [0-9a-f]{8}$", options: .regularExpression) == nil
                ? $0 : nil
        }
        let count = paneCount == 1 ? "1 pane" : "\(paneCount) panes"
        return BackendTerminalSummary(
            kind: .rex,
            address: windowID,
            title: label ?? focusedPaneNames.compactMap(nonBlank).first,
            detail: ([nonBlank(sessionLabel)].compactMap(\.self) + [count])
                .joined(separator: " · ")
        )
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

    /// Rex window IDs look like `window:01a1c874-d309-72f9-b5e6-8ef31add4481`.
    public static func isWindowID(_ value: String) -> Bool {
        value.range(of: "^window:[0-9A-Za-z-]+$", options: .regularExpression) != nil
    }

    private struct Created: Decodable {
        var windowID: String

        enum CodingKeys: String, CodingKey {
            case windowID = "window_id"
        }
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
        var focused: Bool?

        var sessionKey: String { sessionID ?? "" }

        enum CodingKeys: String, CodingKey {
            case blockID = "block_id"
            case label
            case name
            case sessionID = "session_id"
            case sessionLabel = "session_label"
            case windowID = "window_id"
            case windowLabel = "window_label"
            case focused
        }
    }
}
