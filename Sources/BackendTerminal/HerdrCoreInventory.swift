import Foundation
import GhosthubHerdr
import GhosthubTransport
import GhosthubWorkspace

/// Herdr's desktop core owns individual terminals; the older Herdr TUI owns
/// whole sessions and stays in the Herdr module.
public enum HerdrCoreInventory {
    public static let marker = "GHOSTHUB_HC_JSON"
    public static let pathMarker = "GHOSTHUB_HC_PATH"

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

    public static func command(executable: String) -> String {
        let invocation = [executable, "ls", "--json"]
            .map(shellQuotedCommandArgument).joined(separator: " ")
        return [
            HerdrEnvironment.unsetCommand,
            "printf '%s\\n' '\(marker)'",
            "exec \(invocation)",
        ].joined(separator: "; ")
    }

    public static func parse(
        status: Int32,
        stdout: String,
        stderr: String
    ) -> BackendTerminalDiscoveryResult {
        guard status == 0 else {
            return .failure(.commandFailed(.herdrCore, status: status, stderr: stderr))
        }
        guard let payload = MarkedJSON.payload(stdout, after: marker) else {
            return .failure(.missingMarker(.herdrCore))
        }
        guard let inventory = try? JSONDecoder().decode(Inventory.self, from: payload)
        else {
            return .failure(.malformedJSON(.herdrCore))
        }
        var addresses = Set<String>()
        var terminals: [BackendTerminalSummary] = []
        for terminal in inventory.terminals {
            // Core also reports its own remote machines. Ghosthub discovers
            // each configured host itself, without adopting core's SSH routes.
            guard !terminal.address.contains("/"), terminal.state == "live" else { continue }
            guard terminal.address.range(of: "^t[0-9a-z]+$", options: .regularExpression) != nil,
                  addresses.insert(terminal.address).inserted else {
                return .failure(.malformedJSON(.herdrCore))
            }
            let title = [terminal.name, terminal.where, terminal.agent]
                .compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            terminals.append(BackendTerminalSummary(
                kind: .herdrCore,
                address: terminal.address,
                title: title
            ))
        }
        return .available(terminals)
    }

    private struct Inventory: Decodable {
        var terminals: [Terminal]
    }

    private struct Terminal: Decodable {
        var address: String
        var name: String?
        var agent: String?
        var `where`: String?
        var state: String
    }
}
