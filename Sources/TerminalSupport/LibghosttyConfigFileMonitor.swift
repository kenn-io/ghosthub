import Darwin
import Dispatch
import Foundation

public enum LibghosttyConfigFileMonitorError: LocalizedError, Equatable {
    case openFile(URL, Int32)

    public var errorDescription: String? {
        switch self {
        case let .openFile(url, errnoValue):
            return "Failed to watch Ghosthub terminal config at \(url.path): errno \(errnoValue)"
        }
    }
}

public final class LibghosttyConfigFileMonitor {
    public typealias ChangeHandler = @Sendable () -> Void
    public typealias ErrorHandler = @Sendable (
        LibghosttyConfigFileMonitorError
    ) -> Void
    typealias OpenHandler = (_ path: String, _ flags: Int32) -> Int32
    private static let symlinkTraversalLimit = 64

    private struct FileIdentity: Equatable {
        let exists: Bool
        let resolvedPath: String
        let resourceIdentifier: String

        static let missing = FileIdentity(
            exists: false,
            resolvedPath: "",
            resourceIdentifier: ""
        )
    }

    private struct SymlinkCandidate {
        let file: URL
        let expansionDepth: Int
    }

    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let changeHandler: ChangeHandler
    private let errorHandler: ErrorHandler
    private let openHandler: OpenHandler
    private let debounceInterval: DispatchTimeInterval
    private let requiringExistingFiles: Bool

    private var desiredFiles: Set<URL>
    private var knownIdentity: [URL: FileIdentity] = [:]
    private var fileSources:
        [URL: DispatchSourceFileSystemObject] = [:]
    private var directorySources:
        [URL: DispatchSourceFileSystemObject] = [:]
    private var knownDirectoryIdentity: [URL: FileIdentity] = [:]
    private var pendingChange: DispatchWorkItem?
    private var isStarted = false

    public convenience init(
        fileURL: URL,
        queue: DispatchQueue = DispatchQueue(
            label: "com.ghosthub.terminal.config-monitor"
        ),
        debounceInterval: DispatchTimeInterval = .milliseconds(150),
        changeHandler: @escaping ChangeHandler
    ) {
        self.init(
            fileURLs: [fileURL],
            queue: queue,
            debounceInterval: debounceInterval,
            requiringExistingFiles: true,
            changeHandler: changeHandler
        )
    }

    public convenience init(
        fileURLs: [URL],
        queue: DispatchQueue = DispatchQueue(
            label: "com.ghosthub.terminal.config-monitor"
        ),
        debounceInterval: DispatchTimeInterval = .milliseconds(150),
        requiringExistingFiles: Bool = false,
        errorHandler: @escaping ErrorHandler = { _ in },
        changeHandler: @escaping ChangeHandler
    ) {
        self.init(
            fileURLs: fileURLs,
            queue: queue,
            debounceInterval: debounceInterval,
            requiringExistingFiles: requiringExistingFiles,
            openHandler: { path, flags in
                open(path, flags)
            },
            errorHandler: errorHandler,
            changeHandler: changeHandler
        )
    }

    init(
        fileURLs: [URL],
        queue: DispatchQueue,
        debounceInterval: DispatchTimeInterval,
        requiringExistingFiles: Bool,
        openHandler: @escaping OpenHandler,
        errorHandler: @escaping ErrorHandler = { _ in },
        changeHandler: @escaping ChangeHandler
    ) {
        desiredFiles = Set(fileURLs.map(\.standardizedFileURL))
        self.queue = queue
        self.debounceInterval = debounceInterval
        self.requiringExistingFiles = requiringExistingFiles
        self.openHandler = openHandler
        self.errorHandler = errorHandler
        self.changeHandler = changeHandler
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    public func start() throws {
        try synchronized {
            stopLocked()
            if requiringExistingFiles,
               let missing = desiredFiles.first(where: {
                   !fileIdentity(for: $0).exists
               }) {
                throw LibghosttyConfigFileMonitorError.openFile(
                    missing, ENOENT
                )
            }
            isStarted = true
            try configureSourcesLocked()
        }
    }

    public func update(fileURLs: [URL]) throws {
        try synchronized {
            desiredFiles = Set(
                fileURLs.map(\.standardizedFileURL)
            )
            guard isStarted else { return }
            try configureSourcesLocked()
        }
    }

    public func stop() {
        synchronized {
            stopLocked()
        }
    }

    private func stopLocked() {
        pendingChange?.cancel()
        pendingChange = nil
        fileSources.values.forEach { $0.cancel() }
        fileSources.removeAll()
        directorySources.values.forEach { $0.cancel() }
        directorySources.removeAll()
        knownDirectoryIdentity.removeAll()
        knownIdentity.removeAll()
        isStarted = false
    }

    private func configureSourcesLocked() throws {
        fileSources.values.forEach { $0.cancel() }
        fileSources.removeAll()
        directorySources.values.forEach { $0.cancel() }
        directorySources.removeAll()
        knownDirectoryIdentity.removeAll()

        knownIdentity = Dictionary(
            uniqueKeysWithValues: desiredFiles.map {
                ($0, fileIdentity(for: $0))
            }
        )

        for file in desiredFiles
        where knownIdentity[file]?.exists == true {
            try startFileWatchLocked(file)
        }
        try rebuildDirectoryWatchesLocked()
    }

    private func startFileWatchLocked(_ file: URL) throws {
        guard fileSources[file] == nil else { return }
        guard let descriptor = try openDescriptor(for: file)
        else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source,
                  self.fileSources[file] === source
            else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                source.cancel()
                self.fileSources[file] = nil
                self.refreshAfterDirectoryChangeLocked()
                self.scheduleChangeLocked()
            } else {
                self.scheduleChangeLocked()
            }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }
        fileSources[file] = source
        source.resume()
    }

    private func rebuildDirectoryWatchesLocked() throws {
        let directories = watchedDirectories()
        let retainExtraSources = desiredFiles.contains {
            fileIdentity(for: $0).exists == false
        }

        for directory in Set(directorySources.keys) {
            let isNoLongerNeeded = !directories.contains(directory)
            let identityChanged = directories.contains(directory)
                && knownDirectoryIdentity[directory]
                    != fileIdentity(for: directory)
            guard identityChanged
                || (isNoLongerNeeded && !retainExtraSources)
            else { continue }
            directorySources[directory]?.cancel()
            directorySources[directory] = nil
            knownDirectoryIdentity[directory] = nil
        }

        for directory in directories where directorySources[directory] == nil {
            guard let descriptor = try openDescriptor(for: directory)
            else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: queue
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source,
                      self.directorySources[directory] === source
                else { return }
                self.refreshAfterDirectoryChangeLocked()
            }
            source.setCancelHandler { [descriptor] in
                close(descriptor)
            }
            directorySources[directory] = source
            knownDirectoryIdentity[directory] = fileIdentity(
                for: directory
            )
            source.resume()
        }
    }

    private func refreshAfterDirectoryChangeLocked() {
        guard isStarted else { return }
        var identityChanged = reconcileFileSourcesLocked()
        reportingErrors {
            try rebuildDirectoryWatchesLocked()
        }
        let changedDuringRebind = reconcileFileSourcesLocked()
        identityChanged = identityChanged || changedDuringRebind
        if changedDuringRebind {
            reportingErrors {
                try rebuildDirectoryWatchesLocked()
            }
        }
        if identityChanged {
            scheduleChangeLocked()
        }
    }

    private func reconcileFileSourcesLocked() -> Bool {
        var identityChanged = false
        for file in desiredFiles {
            let identity = fileIdentity(for: file)
            if knownIdentity[file] != identity {
                fileSources[file]?.cancel()
                fileSources[file] = nil
                knownIdentity[file] = identity
                identityChanged = true
            }
            if identity.exists, fileSources[file] == nil {
                reportingErrors {
                    try startFileWatchLocked(file)
                }
            }
        }
        return identityChanged
    }

    private func openDescriptor(for url: URL) throws -> Int32? {
        let descriptor = openHandler(url.path, O_EVTONLY)
        guard descriptor < 0 else { return descriptor }
        let openError = errno
        if !requiringExistingFiles, openError == ENOENT {
            return nil
        }
        throw LibghosttyConfigFileMonitorError.openFile(
            url, openError
        )
    }

    private func reportingErrors(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch let error as LibghosttyConfigFileMonitorError {
            errorHandler(error)
        } catch {}
    }

    func watchedDirectories() -> Set<URL> {
        var directories: Set<URL> = []
        for desiredFile in desiredFiles {
            var pending = [
                SymlinkCandidate(
                    file: desiredFile,
                    expansionDepth: 0
                )
            ]
            var visited: Set<URL> = []

            while let candidate = pending.popLast() {
                let standardizedFile = candidate.file.standardizedFileURL
                guard visited.insert(standardizedFile).inserted else {
                    continue
                }
                directories.insert(
                    nearestExistingDirectory(for: standardizedFile)
                )

                var component = URL(
                    fileURLWithPath: "/",
                    isDirectory: true
                )
                let pathComponents = Array(
                    standardizedFile.pathComponents.dropFirst()
                )
                for (index, pathComponent) in pathComponents.enumerated() {
                    component.appendPathComponent(pathComponent)
                    guard isSymbolicLink(component) else { continue }
                    directories.insert(
                        component.deletingLastPathComponent()
                            .standardizedFileURL
                    )
                    guard candidate.expansionDepth
                        < Self.symlinkTraversalLimit,
                        var destination = symlinkDestination(
                            for: component
                        )
                    else { continue }
                    for remaining in pathComponents.dropFirst(index + 1) {
                        destination.appendPathComponent(remaining)
                    }
                    pending.append(
                        SymlinkCandidate(
                            file: destination.standardizedFileURL,
                            expansionDepth: candidate.expansionDepth + 1
                        )
                    )
                }
            }
        }
        return directories
    }

    private func symlinkDestination(for url: URL) -> URL? {
        guard let destination = try? FileManager.default
            .destinationOfSymbolicLink(atPath: url.path)
        else { return nil }
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination)
        }
        return url.deletingLastPathComponent()
            .appendingPathComponent(destination)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return false }
        return metadata.st_mode & S_IFMT == S_IFLNK
    }

    private func nearestExistingDirectory(for file: URL) -> URL {
        var directory = file.deletingLastPathComponent()
            .standardizedFileURL
        while !FileManager.default.fileExists(
            atPath: directory.path
        ) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return directory
    }

    private func fileIdentity(for file: URL) -> FileIdentity {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .missing
        }
        let values = try? file.resourceValues(
            forKeys: [.fileResourceIdentifierKey]
        )
        return FileIdentity(
            exists: true,
            resolvedPath: file.resolvingSymlinksInPath().path,
            resourceIdentifier: String(
                describing: values?.fileResourceIdentifier
            )
        )
    }

    private func scheduleChangeLocked() {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChange = nil
            self.changeHandler()
        }
        pendingChange = work
        queue.asyncAfter(
            deadline: .now() + debounceInterval,
            execute: work
        )
    }

    private func synchronized<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
}
