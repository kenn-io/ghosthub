import Foundation
import GhosthubSettings
import GhosthubWorkspace

enum TailscaleDiscovery {
    static let tailscalePaths: [String] = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    static func discoverPeers() async -> Result<
        [TailscalePeer], TailscaleError
    > {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let binary = findTailscaleBinary()
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
    }

    private static func findTailscaleBinary() -> String? {
        for path in tailscalePaths {
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
