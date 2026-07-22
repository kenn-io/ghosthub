import Foundation

public enum SessionKind: String, Codable, CaseIterable, Sendable {
    case shell
    case preset
    case daemon
}

public enum LaunchMode: String, Codable, CaseIterable, Sendable {
    case loginShell
    case directCommand
}

public enum RestartPolicy: String, Codable, CaseIterable, Sendable {
    case never
    case manual
    case always
}
