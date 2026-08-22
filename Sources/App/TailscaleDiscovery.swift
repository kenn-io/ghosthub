import GhosthubTransport
import Foundation
import GhosthubSettings
import GhosthubTmux
import GhosthubWorkspace

enum TailscaleDiscovery {
    private actor UsernameResolutionQueue {
        private let count: Int
        private var nextIndex = 0

        init(count: Int) {
            self.count = count
        }

        func claim() -> Int? {
            guard nextIndex < count else { return nil }
            defer { nextIndex += 1 }
            return nextIndex
        }
    }

    private enum UsernameResolution: Sendable {
        case peer(index: Int, username: String?)
        case workerFinished
        case deadline
    }

    static let tailscalePaths: [String] = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    static func discoverPeers() async -> Result<
        [TailscalePeer], TailscaleError
    > {
        let environment = ProcessInfo.processInfo.environment
        return await discoverPeers(
            tailscalePaths: candidatePaths(environment: environment),
            environment: environment
        )
    }

    static func candidatePaths(
        environment: [String: String]
    ) -> [String] {
        guard let demoRoot = environment["GHOSTHUB_DEMO_ROOT"],
              demoRoot.hasPrefix("/")
        else { return tailscalePaths }

        return ["\(demoRoot)/bin/tailscale"]
    }

    static func discoverPeers(
        tailscalePaths: [String],
        environment: [String: String],
        sshUsernameProvider: @escaping @Sendable (String) async -> String? = {
            hostname in
            let host = SSHHostInfo(
                user: nil,
                hostname: hostname,
                port: nil
            )
            return try? KwtSSHRouteClient().resolve(host)
                .targets.last?.effectiveTarget.user
        },
        maximumConcurrentUsernameResolutions: Int = 6,
        usernameResolutionTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) async -> Result<[TailscalePeer], TailscaleError> {
        let result: Result<[TailscalePeer], TailscaleError> =
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let binary = findTailscaleBinary(
                        in: tailscalePaths
                    )
                    else {
                        continuation.resume(
                            returning: .failure(.notInstalled)
                        )
                        return
                    }

                    let process = Process()
                    process.executableURL = URL(
                        fileURLWithPath: binary
                    )
                    process.arguments = ["status", "--json"]
                    var processEnvironment = environment
                    processEnvironment["TAILSCALE_BE_CLI"] = "1"
                    process.environment = processEnvironment

                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = FileHandle.nullDevice

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(
                            returning: .failure(
                                .executionFailed(
                                    error.localizedDescription
                                )
                            )
                        )
                        return
                    }

                    let data = pipe.fileHandleForReading
                        .readDataToEndOfFile()
                    process.waitUntilExit()

                    guard process.terminationStatus == 0 else {
                        continuation.resume(
                            returning: .failure(
                                .executionFailed(
                                    "tailscale exited with code"
                                        + " \(process.terminationStatus)"
                                )
                            )
                        )
                        return
                    }
                    let result = TailscaleStatusParser
                        .peers(from: data)
                        .mapError { error in
                            TailscaleError.parseFailed(error.message)
                        }
                    continuation.resume(returning: result)
                }
            }
        guard case let .success(peers) = result else { return result }
        let resolvedPeers = await resolvingSSHUsernames(
            peers,
            maximumConcurrent: maximumConcurrentUsernameResolutions,
            timeoutNanoseconds: usernameResolutionTimeoutNanoseconds,
            provider: sshUsernameProvider
        )
        return .success(resolvedPeers)
    }

    private static func resolvingSSHUsernames(
        _ peers: [TailscalePeer],
        maximumConcurrent: Int,
        timeoutNanoseconds: UInt64,
        provider: @escaping @Sendable (String) async -> String?
    ) async -> [TailscalePeer] {
        guard !peers.isEmpty else { return peers }
        let concurrentCount = min(max(1, maximumConcurrent), peers.count)
        var resolved = peers

        let (resolutions, continuation) = AsyncStream<UsernameResolution>
            .makeStream()
        let queue = UsernameResolutionQueue(count: peers.count)
        let workers = (0 ..< concurrentCount).map { _ in
            Task.detached(priority: .userInitiated) {
                while let index = await queue.claim() {
                    guard !Task.isCancelled else { break }
                    let username = await provider(
                        peers[index].sshAddress
                    )
                    guard !Task.isCancelled else { break }
                    continuation.yield(.peer(
                        index: index,
                        username: username
                    ))
                }
                continuation.yield(.workerFinished)
            }
        }
        let deadline = Task.detached {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                continuation.yield(.deadline)
            } catch {
                // Completion cancels the deadline task.
            }
        }
        defer {
            workers.forEach { $0.cancel() }
            deadline.cancel()
            continuation.finish()
        }

        var finishedWorkerCount = 0
        for await resolution in resolutions {
            switch resolution {
            case let .peer(index, username):
                resolved[index] = peers[index]
                    .resolvingSSHUsername(username)
            case .workerFinished:
                finishedWorkerCount += 1
                if finishedWorkerCount == workers.count {
                    return resolved
                }
            case .deadline:
                return resolved
            }
        }
        return resolved
    }

    private static func findTailscaleBinary(
        in paths: [String]
    ) -> String? {
        for path in paths {
            if FileManager.default.isExecutableFile(
                atPath: path
            ) {
                return path
            }
        }
        return nil
    }
}

enum TailscaleError: Error, Equatable {
    case notInstalled
    case executionFailed(String)
    case parseFailed(String)

    var userMessage: String {
        switch self {
        case .notInstalled:
            return "Tailscale is not installed."
                + " Install Tailscale from tailscale.com"
                + " to import hosts."
        case let .executionFailed(reason):
            return "Failed to query Tailscale: \(reason)"
        case let .parseFailed(reason):
            return "Failed to parse Tailscale status:"
                + " \(reason)"
        }
    }
}

extension Result where Success == [TailscalePeer],
    Failure == TailscaleError {
    var peerLoadResult: TailscalePeerLoadResult {
        switch self {
        case let .success(peers):
            return .success(peers)
        case let .failure(error):
            return .failure(error.userMessage)
        }
    }
}
