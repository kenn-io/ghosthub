import Foundation

/// A single, explicitly requested level of host filesystem inventory from kwt.
public struct DirectoryListing: Decodable, Equatable, Sendable {
    public var path: String
    public var entries: [DirectoryEntry]
    public var truncated: Bool

    public init(path: String, entries: [DirectoryEntry], truncated: Bool = false) {
        self.path = path
        self.entries = entries
        self.truncated = truncated
    }
}

public struct DirectoryEntry: Decodable, Equatable, Identifiable, Sendable {
    public var name: String
    public var path: String
    /// Primary checkout resolved by kwt, including bare-repository containers.
    public var projectPath: String?
    public var id: String { path }

    public init(name: String, path: String, projectPath: String? = nil) {
        self.name = name
        self.path = path
        self.projectPath = projectPath
    }

    private enum CodingKeys: String, CodingKey {
        case name, path
        case projectPath = "project_path"
    }
}

public enum DirectoryPaths {
    /// Compare host paths lexically; never resolve remote paths on the Mac.
    public static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." {
                continue
            }
            if part == ".." {
                if !parts.isEmpty {
                    parts.removeLast()
                }
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func contains(_ parent: String, _ child: String) -> Bool {
        let parent = normalized(parent)
        let child = normalized(child)
        return parent != child && child.hasPrefix(parent == "/" ? "/" : parent + "/")
    }
}
