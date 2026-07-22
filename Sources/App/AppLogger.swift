import Foundation
import GhosthubWorkspace
import os.log

/// File-backed logger that writes timestamped lines to
/// `~/.ghosthub/ghosthub.log`.
///
/// All writes happen on a serial background queue so callers
/// never block on I/O. The log file is created on first write
/// and truncated when it exceeds `maxFileSize`.
final class AppLogger: Sendable {
    static let shared = AppLogger(suppressInTests: true)

    static let defaultMaxFileSize: UInt64 = 4 * 1024 * 1024

    enum Level: String, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private static let osLog = OSLog(
        subsystem: "com.ghosthub.app",
        category: "general"
    )
    private let logFileURL: URL
    private let maxFileSize: UInt64
    private let queue: DispatchQueue

    init(
        logFileURL: URL? = nil,
        maxFileSize: UInt64 = defaultMaxFileSize,
        suppressInTests: Bool = false
    ) {
        self.logFileURL = logFileURL ?? StateHome.resolved()
            .appendingPathComponent("ghosthub.log")
        self.maxFileSize = maxFileSize
        self.suppressInTests = suppressInTests
        queue = DispatchQueue(
            label: "com.ghosthub.logger",
            qos: .utility
        )
    }

    static var logFilePath: String {
        StateHome.resolved()
            .appendingPathComponent("ghosthub.log")
            .path
    }

    func ensureLogFileExists() {
        guard !(suppressInTests && Self.isTestEnvironment) else {
            return
        }
        let fm = FileManager.default
        let dir = logFileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(
                atPath: logFileURL.path,
                contents: nil
            )
        }
    }

    private let suppressInTests: Bool

    private static let isTestEnvironment: Bool = ProcessInfo.processInfo
        .environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    func log(
        _ level: Level,
        _ message: @autoclosure () -> String,
        context: String? = nil
    ) {
        guard !(suppressInTests && Self.isTestEnvironment) else {
            return
        }
        let rendered = message()
        let levelTag = level.rawValue
        let prefix = context.map { "[\($0)] " } ?? ""
        queue.async { [self] in
            let timestamp = Self.formatTimestamp(Date())
            let line = "\(timestamp) \(levelTag) \(prefix)\(rendered)\n"
            writeLine(line)
        }
    }

    /// Thread-safe timestamp formatting without shared mutable
    /// state. Uses POSIX `strftime` + milliseconds instead of
    /// `DateFormatter` which is not safe across queues.
    private static func formatTimestamp(_ date: Date) -> String {
        var time = time_t(date.timeIntervalSince1970)
        var tm = tm()
        localtime_r(&time, &tm)
        let ms = Int(
            date.timeIntervalSince1970
                .truncatingRemainder(dividingBy: 1) * 1000
        )
        var buffer = [CChar](repeating: 0, count: 24)
        strftime(&buffer, buffer.count, "%Y-%m-%d %H:%M:%S", &tm)
        let nullIndex = buffer.firstIndex(of: 0)
            ?? buffer.endIndex
        let timestamp = String(
            decoding: buffer[..<nullIndex].map { UInt8($0) },
            as: UTF8.self
        )
        return timestamp + String(format: ".%03d", ms)
    }

    func debug(
        _ message: @autoclosure () -> String,
        context: String? = nil
    ) {
        log(.debug, message(), context: context)
    }

    func info(
        _ message: @autoclosure () -> String,
        context: String? = nil
    ) {
        log(.info, message(), context: context)
    }

    func warn(
        _ message: @autoclosure () -> String,
        context: String? = nil
    ) {
        log(.warn, message(), context: context)
    }

    func error(
        _ message: @autoclosure () -> String,
        context: String? = nil
    ) {
        log(.error, message(), context: context)
    }

    // MARK: - Private

    private func writeLine(_ line: String) {
        let fm = FileManager.default
        let dir = logFileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }

        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(
                atPath: logFileURL.path,
                contents: nil
            )
        }

        truncateIfNeeded()

        guard let handle = try? FileHandle(
            forWritingTo: logFileURL
        ) else {
            os_log(
                "%{public}@",
                log: Self.osLog,
                type: .error,
                line.trimmingCharacters(in: .newlines)
            )
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }

    private func truncateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: logFileURL.path
        ),
            let size = attrs[.size] as? UInt64,
            size > maxFileSize
        else {
            return
        }

        // Keep the last quarter of the file.
        let keepBytes = Int(maxFileSize / 4)
        guard let data = try? Data(
            contentsOf: logFileURL
        ) else {
            return
        }
        let startIndex = data.count - keepBytes
        guard startIndex > 0 else { return }

        let kept = data.suffix(from: startIndex)
        // Find the first newline to avoid partial lines.
        if let newlineOffset = kept.firstIndex(of: UInt8(ascii: "\n")) {
            let clean = kept.suffix(from: kept.index(after: newlineOffset))
            try? clean.write(to: logFileURL)
        } else {
            try? kept.write(to: logFileURL)
        }
    }
}
