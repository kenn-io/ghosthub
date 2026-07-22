import Dispatch
import Foundation
import Darwin

public enum GhosttyConfigFileMonitorError: LocalizedError, Equatable {
    case openFile(URL, Int32)

    public var errorDescription: String? {
        switch self {
        case let .openFile(url, errnoValue):
            return "Failed to watch Ghostty config file at \(url.path): errno \(errnoValue)"
        }
    }
}

public final class GhosttyConfigFileMonitor {
    public typealias ChangeHandler = @Sendable () -> Void

    private let fileURL: URL
    private let directoryURL: URL
    private let queue: DispatchQueue
    private let changeHandler: ChangeHandler

    private var fileDescriptor: Int32 = -1
    private var fileSource: DispatchSourceFileSystemObject?
    private var directoryDescriptor: Int32 = -1
    private var directorySource: DispatchSourceFileSystemObject?

    public init(
        fileURL: URL,
        queue: DispatchQueue = DispatchQueue(label: "com.ghosthub.terminal.config-monitor"),
        changeHandler: @escaping ChangeHandler
    ) {
        self.fileURL = fileURL
        directoryURL = fileURL.deletingLastPathComponent()
        self.queue = queue
        self.changeHandler = changeHandler
    }

    deinit {
        stop()
    }

    public func start() throws {
        stop()
        try startDirectoryWatch()
        try startFileWatch(requiringExistingFile: true)
    }

    public func stop() {
        fileSource?.cancel()
        fileSource = nil
        fileDescriptor = -1

        directorySource?.cancel()
        directorySource = nil
        directoryDescriptor = -1
    }

    private func startFileWatch(requiringExistingFile: Bool) throws {
        let descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            if requiringExistingFile {
                throw GhosttyConfigFileMonitorError.openFile(fileURL, errno)
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )

        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data

            if events.contains(.delete) || events.contains(.rename) {
                handleWatchedFileReplaced()
            } else {
                changeHandler()
            }
        }

        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }

        fileDescriptor = descriptor
        fileSource = source
        source.resume()
    }

    private func startDirectoryWatch() throws {
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw GhosttyConfigFileMonitorError.openFile(directoryURL, errno)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.reattachFileWatchIfNeeded()
        }

        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }

        directoryDescriptor = descriptor
        directorySource = source
        source.resume()
    }

    private func handleWatchedFileReplaced() {
        fileSource?.cancel()
        fileSource = nil
        fileDescriptor = -1
        reattachFileWatchIfNeeded()
    }

    private func reattachFileWatchIfNeeded() {
        guard fileSource == nil else {
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        try? startFileWatch(requiringExistingFile: false)
        changeHandler()
    }
}
