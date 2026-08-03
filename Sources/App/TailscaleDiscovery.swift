import Foundation
import GhosthubSettings
import GhosthubTmux
import GhosthubWorkspace

enum TailscaleDiscovery {
    private enum UsernameResolution: Sendable {
        case peer(index: Int, username: String?)
        case deadline
        case cancelled
    }

    static let tailscalePaths: [String] = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    static func discoverPeers() async -> Result<
        [TailscalePeer], TailscaleError
    > {
        await discoverPeers(
            tailscalePaths: tailscalePaths,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func discoverPeers(
        tailscalePaths: [String],
        environment: [String: String],
        sshUsernameProvider: @escaping @Sendable (String) async -> String? = {
            hostname in
            await Task.detached(priority: .userInitiated) {
                SSHConfigurationResolver.configuration(for: SSHHostInfo(
                    user: nil,
                    hostname: hostname,
                    port: nil
                ))?.user
            }.value
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

        return await withTaskGroup(of: UsernameResolution.self) { group in
            for index in 0 ..< concurrentCount {
                group.addTask {
                    let username = await provider(
                        peers[index].sshAddress
                    )
                    return .peer(
                        index: index,
                        username: username
                    )
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    return .deadline
                } catch {
                    return .cancelled
                }
            }

            var nextIndex = concurrentCount
            var completedCount = 0
            resolutionLoop: while let resolution = await group.next() {
                switch resolution {
                case let .peer(index, username):
                    resolved[index] = peers[index]
                        .resolvingSSHUsername(username)
                    completedCount += 1
                    if nextIndex < peers.count {
                        let index = nextIndex
                        nextIndex += 1
                        group.addTask {
                            let username = await provider(
                                peers[index].sshAddress
                            )
                            return .peer(
                                index: index,
                                username: username
                            )
                        }
                    } else if completedCount == peers.count {
                        group.cancelAll()
                        break resolutionLoop
                    }
                case .deadline, .cancelled:
                    group.cancelAll()
                    break resolutionLoop
                }
            }
            return resolved
        }
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
