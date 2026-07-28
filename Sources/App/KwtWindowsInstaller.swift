import Foundation
import GhosthubSettings
import GhosthubTmux

enum KwtWindowsInstallError: Error, Equatable, LocalizedError {
    case invalidDestination
    case architectureProbeFailed(status: Int32)
    case unsupportedArchitecture(String)
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
    private let isReadableFile: @Sendable (String) -> Bool
    private let remoteRunner: RemoteRunner
    private let transferRunner: TransferRunner
    private let uploadNameProvider: @Sendable () -> String

    init(
        bundleURL: URL = Bundle.main.bundleURL,
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
                Self.activationCommand(uploadName: uploadName)
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
        uploadName: String
    ) -> String {
        """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        $ghosthubUpload = Join-Path $env:USERPROFILE \(powerShellEncodedArgument(uploadName))
        $ghosthubDirectory = Join-Path $env:USERPROFILE '.ghosthub\\bin'
        $ghosthubDestination = Join-Path $ghosthubDirectory 'kwt.exe'
        $ghosthubStaging = Join-Path $ghosthubDirectory ('kwt-stage-' + [System.Guid]::NewGuid().ToString('N') + '.exe')
        $ghosthubBackup = Join-Path $ghosthubDirectory ('kwt-backup-' + [System.Guid]::NewGuid().ToString('N') + '.exe')
        $ghosthubHadPrevious = $false
        $ghosthubReplacementComplete = $false
        try {
            New-Item -ItemType Directory -Force -Path $ghosthubDirectory | Out-Null
            Move-Item -LiteralPath $ghosthubUpload -Destination $ghosthubStaging
            & $ghosthubStaging '--version' *> $null
            if ($LASTEXITCODE -ne 0) {
                exit $LASTEXITCODE
            }
            if (Test-Path -LiteralPath $ghosthubDestination -PathType Leaf) {
                $ghosthubHadPrevious = $true
                [System.IO.File]::Replace($ghosthubStaging, $ghosthubDestination, $ghosthubBackup, $true)
            } else {
                [System.IO.File]::Move($ghosthubStaging, $ghosthubDestination)
            }
            $ghosthubReplacementComplete = $true
            & $ghosthubDestination '--version' *> $null
            if ($LASTEXITCODE -ne 0) {
                $ghosthubVerificationStatus = $LASTEXITCODE
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
        output
            .split(whereSeparator: \.isNewline)
            .lazy
            .map(String.init)
            .first { $0.hasPrefix(marker) }
            .map { String($0.dropFirst(marker.count)) }
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
        return TmuxBinaryResolver.runProcess(
            executable: "/usr/bin/scp",
            arguments: arguments,
            timeout: 120
        ).status
    }
}
