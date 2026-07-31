import CryptoKit
import Foundation
import GhosthubSettings
import GhosthubTmux

enum KwtWindowsInstallError: Error, Equatable, LocalizedError {
    case invalidDestination
    case architectureProbeFailed(status: Int32)
    case unsupportedArchitecture(String)
    case bundleIncomplete
    case bundledHelperMissing(String)
    case transferFailed(status: Int32)
    case activationFailed(status: Int32)
    case activationUnconfirmed

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "Enter a valid Windows SSH destination."
        case let .architectureProbeFailed(status):
            return "Could not determine the Windows architecture over SSH (status \(status))."
        case let .unsupportedArchitecture(value):
            return "The Windows architecture \(value) is not supported. Ghosthub currently bundles AMD64 and ARM64 kwt."
        case .bundleIncomplete:
            return "This Ghosthub build does not identify a pinned Windows kwt helper."
        case let .bundledHelperMissing(path):
            return "The bundled Windows kwt helper is missing at \(path)."
        case let .transferFailed(status):
            return "Could not upload the bundled Windows kwt helper (status \(status))."
        case let .activationFailed(status):
            return "The uploaded Windows kwt helper could not be installed (status \(status))."
        case .activationUnconfirmed:
            return "Windows did not confirm the bundled kwt installation."
        }
    }
}

struct KwtWindowsInstaller: Sendable {
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo,
        _ command: String
    ) -> (status: Int32, stdout: String)
    typealias TransferRunner = @Sendable (
        _ host: SSHHostInfo,
        _ localPath: String,
        _ remoteName: String
    ) -> Int32

    private static let architectureMarker = "GHOSTHUB_WINDOWS_ARCH="
    private static let installedMarker = "GHOSTHUB_KWT_INSTALLED"

    private let bundleURL: URL
    private let revision: String?
    private let isReadableFile: @Sendable (String) -> Bool
    private let remoteRunner: RemoteRunner
    private let transferRunner: TransferRunner
    private let uploadNameProvider: @Sendable () -> String

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        revision: String? = KwtBinaryLocator.bundledRemoteRevision(),
        isReadableFile: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isReadableFile(atPath: $0)
        },
        remoteRunner: RemoteRunner? = nil,
        transferRunner: TransferRunner? = nil,
        uploadNameProvider: @escaping @Sendable () -> String = {
            "ghosthub-kwt-\(UUID().uuidString).exe"
        }
    ) {
        self.bundleURL = bundleURL
        self.revision = revision
        self.isReadableFile = isReadableFile
        self.remoteRunner = remoteRunner ?? { host, command in
            TmuxBinaryResolver.runRemoteLoginShell(
                host: host,
                command: command,
                timeout: 30
            )
        }
        self.transferRunner = transferRunner ?? Self.transfer
        self.uploadNameProvider = uploadNameProvider
    }

    func install(on configuredHost: SSHHost) async
        -> Result<Void, KwtWindowsInstallError> {
        guard let revision,
              let managedRelativePath =
              KwtBinaryLocator.windowsRemoteManagedRelativePath(
                  revision: revision
              )
        else {
            return .failure(.bundleIncomplete)
        }
        guard let parsed = TmuxHostResolver.parseSSHDestination(
            configuredHost.sshDestination
        ) else {
            return .failure(.invalidDestination)
        }
        let host = SSHHostInfo(
            user: parsed.user,
            hostname: parsed.hostname,
            port: parsed.port,
            platform: .windows
        )
        let remoteRunner = remoteRunner
        let architectureResult = await Task.detached {
            remoteRunner(host, Self.architectureCommand)
        }.value
        guard architectureResult.status == 0 else {
            return .failure(.architectureProbeFailed(
                status: architectureResult.status
            ))
        }
        guard let rawArchitecture = Self.markedValue(
            in: architectureResult.stdout,
            marker: Self.architectureMarker
        ) else {
            return .failure(.unsupportedArchitecture("unknown"))
        }
        guard let architecture = KwtBinaryLocator.WindowsArchitecture(
            remoteValue: rawArchitecture
        ) else {
            return .failure(.unsupportedArchitecture(rawArchitecture))
        }
        let localPath = KwtBinaryLocator.windowsBundledPath(
            architecture: architecture,
            bundleURL: bundleURL
        )
        guard isReadableFile(localPath) else {
            return .failure(.bundledHelperMissing(localPath))
        }
        guard let helperData = try? Data(
            contentsOf: URL(fileURLWithPath: localPath)
        ) else {
            return .failure(.bundledHelperMissing(localPath))
        }
        let digest = SHA256.hash(data: helperData)
            .map { String(format: "%02x", $0) }
            .joined()

        let uploadName = uploadNameProvider()
        let transferRunner = transferRunner
        let transferStatus = await Task.detached {
            transferRunner(host, localPath, uploadName)
        }.value
        guard transferStatus == 0 else {
            return .failure(.transferFailed(status: transferStatus))
        }

        let activationResult = await Task.detached {
            remoteRunner(
                host,
                Self.activationCommand(
                    uploadName: uploadName,
                    managedRelativePath: managedRelativePath,
                    revision: revision,
                    digest: digest
                )
            )
        }.value
        guard activationResult.status == 0 else {
            return .failure(.activationFailed(
                status: activationResult.status
            ))
        }
        guard activationResult.stdout.contains(Self.installedMarker) else {
            return .failure(.activationUnconfirmed)
        }
        return .success(())
    }

    private static let architectureCommand = """
    $ErrorActionPreference = 'Stop'
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [Console]::OutputEncoding
    Write-Output ('\(
        architectureMarker
    )' + [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString())
    """

    private static func activationCommand(
        uploadName: String,
        managedRelativePath: String,
        revision: String,
        digest: String
    ) -> String {
        let expectedVersion = "kwt version \(revision)"
        return """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        $ghosthubUpload = Join-Path $env:USERPROFILE \(powerShellEncodedArgument(uploadName))
        $ghosthubDestination = Join-Path $env:USERPROFILE \(
            powerShellEncodedArgument(managedRelativePath)
        )
        $ghosthubDirectory = Split-Path -Parent $ghosthubDestination
        $ghosthubStaging = Join-Path $ghosthubDirectory ('kwt-stage-' + [System.Guid]::NewGuid().ToString('N') + '.exe')
        $ghosthubBackup = Join-Path $ghosthubDirectory ('kwt-backup-' + [System.Guid]::NewGuid().ToString('N') + '.exe')
        $ghosthubHadPrevious = $false
        $ghosthubReplacementComplete = $false
        try {
            New-Item -ItemType Directory -Force -Path $ghosthubDirectory | Out-Null
            Move-Item -LiteralPath $ghosthubUpload -Destination $ghosthubStaging
            $ghosthubDigest = (Get-FileHash -LiteralPath $ghosthubStaging -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($ghosthubDigest -cne \(powerShellEncodedArgument(digest))) {
                exit 65
            }
            $ghosthubVersionOutput = @(& $ghosthubStaging 'version')
            $ghosthubVersionStatus = $LASTEXITCODE
            if ($ghosthubVersionStatus -ne 0) {
                exit $ghosthubVersionStatus
            }
            if (($ghosthubVersionOutput.Count -eq 0) -or ([string]$ghosthubVersionOutput[0] -cne \(
                powerShellEncodedArgument(expectedVersion)
            ))) {
                exit 66
            }
            if (Test-Path -LiteralPath $ghosthubDestination -PathType Leaf) {
                $ghosthubHadPrevious = $true
                [System.IO.File]::Replace($ghosthubStaging, $ghosthubDestination, $ghosthubBackup, $true)
            } else {
                [System.IO.File]::Move($ghosthubStaging, $ghosthubDestination)
            }
            $ghosthubReplacementComplete = $true
            $ghosthubInstalledVersionOutput = @(& $ghosthubDestination 'version')
            $ghosthubVerificationStatus = $LASTEXITCODE
            $ghosthubInstalledVersionMatches = ($ghosthubInstalledVersionOutput.Count -gt 0) -and ([string]$ghosthubInstalledVersionOutput[0] -ceq \(
                powerShellEncodedArgument(expectedVersion)
            ))
            if (($ghosthubVerificationStatus -ne 0) -or (-not $ghosthubInstalledVersionMatches)) {
                if ($ghosthubVerificationStatus -eq 0) {
                    $ghosthubVerificationStatus = 66
                }
                if ($ghosthubHadPrevious -and (Test-Path -LiteralPath $ghosthubBackup -PathType Leaf)) {
                    [System.IO.File]::Replace($ghosthubBackup, $ghosthubDestination, $null, $true)
                } else {
                    Remove-Item -LiteralPath $ghosthubDestination -Force -ErrorAction SilentlyContinue
                }
                exit $ghosthubVerificationStatus
            }
            Remove-Item -LiteralPath $ghosthubBackup -Force -ErrorAction SilentlyContinue
            Write-Output '\(installedMarker)'
        } catch {
            if ($ghosthubReplacementComplete) {
                if ($ghosthubHadPrevious -and (Test-Path -LiteralPath $ghosthubBackup -PathType Leaf)) {
                    [System.IO.File]::Replace($ghosthubBackup, $ghosthubDestination, $null, $true)
                } else {
                    Remove-Item -LiteralPath $ghosthubDestination -Force -ErrorAction SilentlyContinue
                }
            }
            throw
        } finally {
            Remove-Item -LiteralPath $ghosthubUpload -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $ghosthubStaging -Force -ErrorAction SilentlyContinue
        }
        """
    }

    private static func markedValue(
        in output: String,
        marker: String
    ) -> String? {
        let normalizedOutput = output.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )
        guard let markerRange = normalizedOutput.range(
            of: marker,
            options: .backwards
        ) else {
            return nil
        }
        let value = normalizedOutput[markerRange.upperBound...]
            .prefix(while: { !$0.isNewline })
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func transfer(
        host: SSHHostInfo,
        localPath: String,
        remoteName: String
    ) -> Int32 {
        var arguments = [
            "-q",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=15",
        ]
        arguments.append(contentsOf: tmuxSSHConnectionArguments())
        if let port = host.port, port != 22 {
            arguments += ["-P", String(port)]
        }
        let hostname = host.hostname.contains(":")
            ? "[\(host.hostname)]"
            : host.hostname
        let destination = host.user.map { "\($0)@\(hostname)" } ?? hostname
        arguments += [
            "--",
            localPath,
            "\(destination):\(remoteName)",
        ]
        return TmuxBinaryResolver.runProcessInLoginShell(
            executable: "/usr/bin/scp",
            arguments: arguments,
            timeout: 120
        ).status
    }
}
