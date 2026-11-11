import Foundation
import GhosthubWorkspace

/// One backend's terminal inventory on one host. A missing backend is a
/// normal, silent state.
public enum BackendTerminalDiscoveryResult: Equatable, Sendable {
    case available([BackendTerminalSummary])
    case unavailable
    case failure(BackendTerminalCommandError)
}

/// Inventory commands print a marker line before their JSON, so login-shell
/// banners and messages before it are ignored.
enum MarkedJSON {
    static func payload(
        _ stdout: String,
        after marker: String
    ) -> Data? {
        let lines = stdout.components(separatedBy: "\n")
        guard let start = lines.lastIndex(of: marker) else { return nil }
        return Data(lines.dropFirst(start + 1).joined(separator: "\n").utf8)
    }
}
