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
    private static let coverageRetryLimit = 4
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

    private struct WatchGraph: Equatable {
        let files: Set<URL>
        let fileIdentities: [URL: FileIdentity]
        let directories: Set<URL>
        let directoryIdentities: [URL: FileIdentity]
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
    private var pendingDirectoryRecheck: DispatchWorkItem?
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
            try reconfigureSourcesLocked(
                to: desiredFiles,
                keepStagedSourcesOnFailure: true
            )
        }
    }

    public func update(fileURLs: [URL]) throws {
        try synchronized {
            let updatedFiles = Set(
                fileURLs.map(\.standardizedFileURL)
            )
            guard isStarted else { return }
            guard updatedFiles != desiredFiles
                || !sourcesAreCurrentLocked(for: updatedFiles)
            else { return }
            try reconfigureSourcesLocked(to: updatedFiles)
        }
    }

    public func stop() {
        synchronized {
            stopLocked()
        }
    }

    private func stopLocked() {
        pendingDirectoryRecheck?.cancel()
        pendingDirectoryRecheck = nil
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

    private func installFileSourceLocked(
        for file: URL,
        descriptor: Int32
    ) {
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

    private func installDirectorySourceLocked(
        for directory: URL,
        descriptor: Int32,
        identity: FileIdentity
    ) {
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
        knownDirectoryIdentity[directory] = identity
        source.resume()
    }

    private func reconfigureSourcesLocked(
        to updatedFiles: Set<URL>,
        keepStagedSourcesOnFailure: Bool = false,
        remainingCoverageRetries: Int =
            LibghosttyConfigFileMonitor.coverageRetryLimit
    ) throws {
        let graph = watchGraphLocked(for: updatedFiles)
        var stagedFiles: [URL: Int32] = [:]
        var stagedDirectories: [URL: Int32] = [:]

        do {
            for file in graph.files
            where graph.fileIdentities[file]?.exists == true {
                let sourceIsCurrent = fileSources[file] != nil
                    && knownIdentity[file]
                        == graph.fileIdentities[file]
                guard !sourceIsCurrent,
                      let descriptor = try openDescriptor(for: file)
                else { continue }
                stagedFiles[file] = descriptor
            }
            for directory in graph.directories {
                let sourceIsCurrent = directorySources[directory] != nil
                    && knownDirectoryIdentity[directory]
                        == graph.directoryIdentities[directory]
                guard !sourceIsCurrent,
                      let descriptor = try openDescriptor(for: directory)
                else { continue }
                stagedDirectories[directory] = descriptor
            }
        } catch {
            if keepStagedSourcesOnFailure {
                applyStagedSourcesLocked(
                    files: graph.files,
                    identities: graph.fileIdentities,
                    directories: graph.directories,
                    directoryIdentities: graph.directoryIdentities,
                    stagedFiles: stagedFiles,
                    stagedDirectories: stagedDirectories
                )
            } else {
                closeStagedDescriptors(
                    files: stagedFiles,
                    directories: stagedDirectories
                )
            }
            throw error
        }

        let refreshedGraph = watchGraphLocked(for: updatedFiles)
        let uncovered = proposedCoverageGapLocked(
            graph: graph,
            stagedFiles: stagedFiles,
            stagedDirectories: stagedDirectories
        )
        guard graph == refreshedGraph, uncovered == nil else {
            closeStagedDescriptors(
                files: stagedFiles,
                directories: stagedDirectories
            )
            guard remainingCoverageRetries > 0 else {
                throw LibghosttyConfigFileMonitorError.openFile(
                    uncovered
                        ?? graphDifferenceURL(
                            graph,
                            refreshedGraph
                        ),
                    ENOENT
                )
            }
            try reconfigureSourcesLocked(
                to: updatedFiles,
                keepStagedSourcesOnFailure: keepStagedSourcesOnFailure,
                remainingCoverageRetries:
                    remainingCoverageRetries - 1
            )
            return
        }

        // No live source is cancelled until the proposed graph has complete
        // coverage and the filesystem snapshot is stable.
        applyStagedSourcesLocked(
            files: graph.files,
            identities: graph.fileIdentities,
            directories: graph.directories,
            directoryIdentities: graph.directoryIdentities,
            stagedFiles: stagedFiles,
            stagedDirectories: stagedDirectories
        )
    }

    private func watchGraphLocked(
        for files: Set<URL>
    ) -> WatchGraph {
        let fileIdentities = Dictionary(
            uniqueKeysWithValues: files.map {
                ($0, fileIdentity(for: $0))
            }
        )
        let directories = watchedDirectories(for: files)
        let directoryIdentities = Dictionary(
            uniqueKeysWithValues: directories.map {
                ($0, fileIdentity(for: $0))
            }
        )
        return WatchGraph(
            files: files,
            fileIdentities: fileIdentities,
            directories: directories,
            directoryIdentities: directoryIdentities
        )
    }

    private func proposedCoverageGapLocked(
        graph: WatchGraph,
        stagedFiles: [URL: Int32],
        stagedDirectories: [URL: Int32]
    ) -> URL? {
        for (file, identity) in graph.fileIdentities
        where identity.exists {
            let existingSourceIsCurrent = fileSources[file] != nil
                && knownIdentity[file] == identity
            if !existingSourceIsCurrent, stagedFiles[file] == nil {
                return file
            }
        }
        for directory in graph.directories {
            let existingSourceIsCurrent =
                directorySources[directory] != nil
                    && knownDirectoryIdentity[directory]
                        == graph.directoryIdentities[directory]
            if !existingSourceIsCurrent,
               stagedDirectories[directory] == nil {
                return directory
            }
        }
        return nil
    }

    private func graphDifferenceURL(
        _ first: WatchGraph,
        _ second: WatchGraph
    ) -> URL {
        for file in first.files.union(second.files)
        where first.fileIdentities[file] != second.fileIdentities[file] {
            return file
        }
        for directory in first.directories.union(second.directories)
        where first.directoryIdentities[directory]
            != second.directoryIdentities[directory] {
            return directory
        }
        return first.files.first
            ?? first.directories.first
            ?? URL(fileURLWithPath: "/")
    }

    private func closeStagedDescriptors(
        files: [URL: Int32],
        directories: [URL: Int32]
    ) {
        files.values.forEach { close($0) }
        directories.values.forEach { close($0) }
    }

    private func sourcesAreCurrentLocked(
        for files: Set<URL>
    ) -> Bool {
        coverageGapLocked(for: files) == nil
    }

    private func coverageGapLocked(
        for files: Set<URL>
    ) -> URL? {
        let graph = watchGraphLocked(for: files)
        if knownIdentity != graph.fileIdentities {
            return files.first {
                knownIdentity[$0] != graph.fileIdentities[$0]
            }
        }
        for (file, identity) in graph.fileIdentities
        where identity.exists && fileSources[file] == nil {
            return file
        }
        for directory in graph.directories {
            guard directorySources[directory] != nil,
                  knownDirectoryIdentity[directory]
                    == graph.directoryIdentities[directory]
            else { return directory }
        }
        return nil
    }

    private func applyStagedSourcesLocked(
        files: Set<URL>,
        identities: [URL: FileIdentity],
        directories: Set<URL>,
        directoryIdentities: [URL: FileIdentity],
        stagedFiles: [URL: Int32],
        stagedDirectories: [URL: Int32]
    ) {
        let missingFiles = Set(
            identities.compactMap { file, identity in
                identity.exists ? nil : file
            }
        )
        let missingDirectories = watchedDirectories(
            for: missingFiles
        )
        for file in Set(fileSources.keys) {
            let shouldRemove = !files.contains(file)
                || knownIdentity[file] != identities[file]
            guard shouldRemove else { continue }
            fileSources[file]?.cancel()
            fileSources[file] = nil
        }
        for directory in Set(directorySources.keys) {
            let isNoLongerNeeded = !directories.contains(
                directory
            )
            let identityChanged = directories.contains(directory)
                && knownDirectoryIdentity[directory]
                    != directoryIdentities[directory]
            let isRequiredAncestor = missingDirectories.contains {
                isAncestor(directory, of: $0)
            }
            guard identityChanged
                || (isNoLongerNeeded && !isRequiredAncestor)
            else { continue }
            directorySources[directory]?.cancel()
            directorySources[directory] = nil
            knownDirectoryIdentity[directory] = nil
        }

        desiredFiles = files
        knownIdentity = identities

        for (file, descriptor) in stagedFiles {
            installFileSourceLocked(
                for: file,
                descriptor: descriptor
            )
        }
        for (directory, descriptor) in stagedDirectories {
            installDirectorySourceLocked(
                for: directory,
                descriptor: descriptor,
                identity: directoryIdentities[directory] ?? .missing
            )
        }
    }

    private func isAncestor(
        _ candidate: URL,
        of descendant: URL
    ) -> Bool {
        let candidateComponents = candidate.standardizedFileURL
            .pathComponents
        let descendantComponents = descendant.standardizedFileURL
            .pathComponents
        guard candidateComponents.count <= descendantComponents.count
        else { return false }
        return zip(
            candidateComponents,
            descendantComponents
        ).allSatisfy { candidate, descendant in
            candidate == descendant
        }
    }

    private func refreshAfterDirectoryChangeLocked() {
        guard isStarted else { return }
        let previousIdentity = knownIdentity
        let observedIdentity = Dictionary(
            uniqueKeysWithValues: desiredFiles.map {
                ($0, fileIdentity(for: $0))
            }
        )
        reportingErrors {
            try reconfigureSourcesLocked(to: desiredFiles)
        }
        if previousIdentity != observedIdentity
            || previousIdentity != knownIdentity {
            scheduleChangeLocked()
        } else {
            scheduleDirectoryRecheckLocked()
        }
    }

    private func scheduleDirectoryRecheckLocked() {
        pendingDirectoryRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDirectoryRecheck = nil
            let previousIdentity = self.knownIdentity
            let observedIdentity = Dictionary(
                uniqueKeysWithValues: self.desiredFiles.map {
                    ($0, self.fileIdentity(for: $0))
                }
            )
            self.reportingErrors {
                try self.reconfigureSourcesLocked(
                    to: self.desiredFiles
                )
            }
            if previousIdentity != observedIdentity
                || previousIdentity != self.knownIdentity {
                self.scheduleChangeLocked()
            }
        }
        pendingDirectoryRecheck = work
        queue.asyncAfter(
            deadline: .now() + debounceInterval,
            execute: work
        )
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
        watchedDirectories(for: desiredFiles)
    }

    func activeWatchedDirectories() -> Set<URL> {
        synchronized {
            Set(directorySources.keys)
        }
    }

    private func watchedDirectories(
        for files: Set<URL>
    ) -> Set<URL> {
        var directories: Set<URL> = []
        for desiredFile in files {
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
