import Foundation

/// A single, explicitly requested level of host filesystem inventory from kwt.
public struct DirectoryListing: Decodable, Equatable, Sendable {
    public var path: String
    public var entries: [DirectoryEntry]
    public var truncated: Bool
    /// Transport authority observed by the app, never accepted from helper JSON.
    public var routeIdentity: String?

    private enum CodingKeys: String, CodingKey {
        case path, entries, truncated
    }

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
    public var presentsProject = true
    public var id: Data { Data(path.utf8) }

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
    public static func key(_ path: String) -> Data {
        Data(normalized(path).utf8)
    }

    /// Compare host paths lexically; never resolve remote paths on the Mac.
    public static func normalized(_ path: String) -> String {
        var parts: [String] = []
        for bytes in path.utf8.split(separator: 0x2F) {
            let part = String(decoding: bytes, as: UTF8.self)
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
        let parent = key(parent)
        let child = key(child)
        let prefix = parent == Data([0x2F]) ? parent : parent + Data([0x2F])
        return parent != child && child.starts(with: prefix)
    }
}
