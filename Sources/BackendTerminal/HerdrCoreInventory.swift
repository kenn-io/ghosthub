import Foundation
import GhosthubHerdr
import GhosthubTransport
import GhosthubWorkspace

/// Herdr's desktop core owns individual terminals; the older Herdr TUI owns
/// whole sessions and stays in the Herdr module.
public enum HerdrCoreInventory {
    public static let marker = "GHOSTHUB_HC_JSON"
    public static let pathMarker = "GHOSTHUB_HC_PATH"
    /// Comes before a desktop tab's event stream from `herdr-core connect`.
    public static let eventsMarker = "GHOSTHUB_HC_EVENTS"
    /// Asks a plain connection for every change: terminals and documents.
    public static let eventsRequest =
        #"{"jsonrpc":"2.0","id":1,"method":"events.subscribe","params":{}}"#
    /// Comes before the core's reply to reading the desktop layout.
    public static let documentMarker = "GHOSTHUB_HC_DOC"
    /// Reads the layout document of the Herdr desktop app.
    public static let documentRequest =
        #"{"jsonrpc":"2.0","id":1,"method":"doc.get","params":{"name":"herdr-app"}}"#

    /// Resolves `herdr-core` in the account's login environment. Exit 127
    /// means it is not installed.
    public static var executableCommand: String {
        [
            HerdrEnvironment.unsetCommand,
            "ghosthub_herdr_path=$(command -v herdr-core) || exit 127",
            "[ -n \"$ghosthub_herdr_path\" ] || exit 127",
            "case \"$ghosthub_herdr_path\" in /*) ;; *) exit 127 ;; esac",
            "[ -x \"$ghosthub_herdr_path\" ] || exit 127",
            "printf '%s\\n%s\\n' '\(pathMarker)' \"$ghosthub_herdr_path\"",
        ].joined(separator: "; ")
    }

    /// Lists the terminals, then reads the desktop app's layout document.
    /// A core that cannot read the document still lists its terminals.
    public static func command(executable: String) -> String {
        func invocation(_ arguments: String...) -> String {
            ([executable] + arguments).map(shellQuotedCommandArgument).joined(separator: " ")
        }
        return [
            HerdrEnvironment.unsetCommand,
            "printf '%s\\n' '\(marker)'",
            "\(invocation("ls", "--json")) || exit",
            "printf '%s\\n' '\(documentMarker)'",
            "printf '%s\\n' \(shellQuotedCommandArgument(documentRequest)) | "
                + "\(invocation("connect")) 2>/dev/null",
            "exit 0",
        ].joined(separator: "; ")
    }

    public static func parse(
        status: Int32,
        stdout: String,
        stderr: String
    ) -> BackendTerminalDiscoveryResult {
        switch parseListing(status: status, stdout: stdout, stderr: stderr) {
        case let .success(listing): .available(listing.rows)
        case let .failure(error): .failure(error)
        }
    }

    public static func parseListing(
        status: Int32,
        stdout: String,
        stderr: String
    ) -> Result<HerdrCoreListing, BackendTerminalCommandError> {
        guard status == 0 else {
            return .failure(.commandFailed(.herdrCore, status: status, stderr: stderr))
        }
        var lines = stdout.components(separatedBy: "\n")
        var reply = Data()
        if let index = lines.lastIndex(of: documentMarker) {
            reply = Data(lines[(index + 1)...].joined(separator: "\n").utf8)
            lines.removeSubrange(index...)
        }
        guard let payload = MarkedJSON.payload(lines.joined(separator: "\n"), after: marker) else {
            return .failure(.missingMarker(.herdrCore))
        }
        guard let inventory = try? JSONDecoder().decode(Inventory.self, from: payload)
        else {
            return .failure(.malformedJSON(.herdrCore))
        }
        var live: [Terminal] = []
        var addresses = Set<String>()
        for terminal in inventory.terminals {
            // Core also reports its own remote machines. Ghosthub discovers
            // each configured host itself, without adopting core's SSH routes.
            guard !terminal.address.contains("/"), terminal.state == "live" else { continue }
            guard terminal.address.range(of: "^t[0-9a-z]+$", options: .regularExpression) != nil,
                  addresses.insert(terminal.address).inserted else {
                return .failure(.malformedJSON(.herdrCore))
            }
            live.append(terminal)
        }
        let tabs = HerdrCoreLayout.tabs(reply: reply, live: addresses)
        let inTabs = Set(tabs.flatMap(\.root.paneIDs))
        let rows = tabs.map { tab in
            tabRow(
                address: tab.address, name: tab.name, spaceName: tab.spaceName,
                paneCount: tab.root.paneIDs.count
            )
        }
            + live.filter { !inTabs.contains($0.address) }.map { terminal in
                BackendTerminalSummary(
                    kind: .herdrCore,
                    address: terminal.address,
                    title: nonBlank(terminal.name) ?? nonBlank(terminal.where)
                        ?? nonBlank(terminal.agent)
                )
            }
        return .success(HerdrCoreListing(
            rows: rows,
            tabs: tabs,
            paneNames: Dictionary(uniqueKeysWithValues: live.compactMap { terminal in
                (nonBlank(terminal.name) ?? nonBlank(terminal.agent)).map { (terminal.address, $0) }
            }),
            paneDirectories: Dictionary(uniqueKeysWithValues: live.compactMap { terminal in
                nonBlank(terminal.cwd).map { (terminal.address, $0) }
            })
        ))
    }

    /// A desktop tab's sidebar row: its name, then its space and panes. A
    /// tab without a name takes its space's, which the detail then omits.
    public static func tabRow(
        address: String, name: String, spaceName: String, paneCount: Int
    ) -> BackendTerminalSummary {
        let count = paneCount == 1 ? "1 pane" : "\(paneCount) panes"
        let title = nonBlank(name) ?? nonBlank(spaceName)
        let space = nonBlank(spaceName).flatMap { $0 == title ? nil : $0 }
        return BackendTerminalSummary(
            kind: .herdrCore,
            address: address,
            title: title,
            detail: ([space].compactMap(\.self) + [count]).joined(separator: " · ")
        )
    }

    /// A desktop tab's address, `tab:` and the desktop app's tab ID, such
    /// as `tab:tb3f9a…`. Anything else could be read as a command option.
    public static func isTabAddress(_ value: String) -> Bool {
        WorkspaceBackendTerminalSelection.isHerdrCoreTabAddress(value)
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private struct Inventory: Decodable {
        var terminals: [Terminal]
    }

    private struct Terminal: Decodable {
        var address: String
        var name: String?
        var agent: String?
        var `where`: String?
        var cwd: String?
        var state: String
    }
}
