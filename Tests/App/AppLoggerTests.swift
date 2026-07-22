import Foundation
import GhosthubTestSupport
import Testing
@testable import GhosthubApp

struct AppLoggerTests {
    private let tempFixture: TempDirectoryFixture

    init() throws {
        tempFixture = try TempDirectoryFixture()
    }

    private func makeLogger(
        maxFileSize: UInt64 = AppLogger.defaultMaxFileSize
    ) -> (AppLogger, URL) {
        let logFile = tempFixture.url
            .appendingPathComponent("test.log")
        let logger = AppLogger(
            logFileURL: logFile,
            maxFileSize: maxFileSize
        )
        return (logger, logFile)
    }

    private func expectLog(
        _ url: URL,
        contains expectedStrings: String...,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let contents = try String(contentsOf: url, encoding: .utf8)
        for expected in expectedStrings {
            #expect(
                contents.contains(expected),
                sourceLocation: sourceLocation
            )
        }
    }

    private func waitForWrite() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test("log creates the file and writes a timestamped line")
    func logCreatesFileAndWritesLine() async throws {
        let (logger, logFile) = makeLogger()

        logger.info("hello world")
        await waitForWrite()

        try expectLog(logFile, contains: "INFO hello world")
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        #expect(contents.hasSuffix("\n"))
    }

    @Test("log includes context prefix when provided")
    func logIncludesContext() async throws {
        let (logger, logFile) = makeLogger()

        logger.error("disk full", context: "persistence")
        await waitForWrite()

        try expectLog(
            logFile,
            contains: "ERROR [persistence] disk full"
        )
    }

    @Test("all log levels are written")
    func allLevelsWritten() async throws {
        let (logger, logFile) = makeLogger()

        logger.debug("d")
        logger.info("i")
        logger.warn("w")
        logger.error("e")
        await waitForWrite()

        try expectLog(
            logFile,
            contains: "DEBUG d", "INFO i", "WARN w", "ERROR e"
        )
    }

    @Test("log truncates when file exceeds max size")
    func logTruncatesOnOverflow() async throws {
        let (logger, logFile) = makeLogger(maxFileSize: 512)

        for i in 0 ..< 100 {
            logger.info(
                "line \(i) padding \(String(repeating: "x", count: 20))"
            )
        }
        await waitForWrite()

        let data = try Data(contentsOf: logFile)
        #expect(data.count < 512)
        let contents = String(data: data, encoding: .utf8) ?? ""
        #expect(!contents.contains("line 0 "))
    }

    @Test("ensureLogFileExists creates the file")
    func ensureLogFileExists() {
        let (logger, logFile) = makeLogger()

        #expect(!FileManager.default.fileExists(atPath: logFile.path))
        logger.ensureLogFileExists()
        #expect(FileManager.default.fileExists(atPath: logFile.path))
    }

    @Test("logFilePath returns expected path")
    func logFilePathIsCorrect() {
        let path = AppLogger.logFilePath
        #expect(path.hasSuffix(".ghosthub/ghosthub.log"))
    }
}
