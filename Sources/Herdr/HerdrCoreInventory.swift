import Foundation
import GhosthubTransport
import GhosthubWorkspace

/// Core owns individual terminals, while the older TUI owns whole sessions.
public enum HerdrCoreInventory {
    public static let marker = "GHOSTHUB_HC_JSON"

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
    ) -> HerdrDiscoveryResult {
        guard status == 0 else {
            return .failure(.commandFailed(status: status, stderr: stderr))
        }
        let lines = stdout.components(separatedBy: "\n")
        guard let start = lines.lastIndex(of: marker) else {
            return .failure(.missingMarker)
        }
        let payload = lines.dropFirst(start + 1).joined(separator: "\n")
        guard let inventory = try? JSONDecoder().decode(Inventory.self, from: Data(payload.utf8))
        else {
            return .failure(.malformedJSON)
        }
        var addresses = Set<String>()
        var sessions: [HerdrSessionSummary] = []
        for terminal in inventory.terminals {
            // Core also reports its own remote machines. Ghosthub discovers
            // each configured host itself, without adopting core's SSH routes.
            guard !terminal.address.contains("/"), terminal.state == "live" else { continue }
            guard terminal.address.range(of: "^t[0-9a-z]+$", options: .regularExpression) != nil,
                  addresses.insert(terminal.address).inserted else {
                return .failure(.malformedJSON)
            }
            let title = [terminal.name, terminal.agent, terminal.address]
                .compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            sessions.append(HerdrSessionSummary(
                name: terminal.address,
                isDefault: false,
                state: .running,
                backend: .core,
                title: title
            ))
        }
        return .available(sessions, tuiAvailable: false)
    }

    private struct Inventory: Decodable {
        var terminals: [Terminal]
    }

    private struct Terminal: Decodable {
        var address: String
        var name: String?
        var agent: String?
        var state: String
    }
}
