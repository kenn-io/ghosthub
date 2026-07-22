import Foundation

public final class TempDirectoryFixture {
    public let url: URL

    public init(shortPath: Bool = false) throws {
        let baseDir: URL
        if shortPath {
            baseDir = URL(fileURLWithPath: "/tmp")
            url = baseDir.appendingPathComponent(
                "gh-\(UUID().uuidString.prefix(8))", isDirectory: true
            )
        } else {
            baseDir = FileManager.default.temporaryDirectory
            url = baseDir.appendingPathComponent(
                UUID().uuidString, isDirectory: true
            )
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    public func createExecutable(
        name: String = "roborev",
        content: String = "#!/bin/sh\nexit 0\n"
    ) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: fileURL.path,
            contents: Data(content.utf8)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fileURL.path
        )
        return fileURL
    }

    public func childURL(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    public func write(
        _ contents: String,
        to target: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(
            to: target, atomically: true, encoding: .utf8
        )
    }

    @discardableResult
    public func write(
        _ contents: String,
        toRelativePath path: String
    ) throws -> URL {
        let fileURL = childURL(path)
        try write(contents, to: fileURL)
        return fileURL
    }

    public func read(relativePath path: String) throws -> String {
        try String(
            contentsOf: childURL(path), encoding: .utf8
        )
    }

    public func fileExists(
        relativePath path: String
    ) -> Bool {
        FileManager.default.fileExists(
            atPath: childURL(path).path
        )
    }

    @discardableResult
    public func createSubdirectory(
        _ relativePath: String
    ) throws -> URL {
        let dirURL = childURL(relativePath)
        try FileManager.default.createDirectory(
            at: dirURL, withIntermediateDirectories: true
        )
        return dirURL
    }
}

public func withTemporaryDirectory<T>(
    perform body: (URL) throws -> T
) throws -> T {
    let fixture = try TempDirectoryFixture()
    return try withExtendedLifetime(fixture) {
        try body(fixture.url)
    }
}
