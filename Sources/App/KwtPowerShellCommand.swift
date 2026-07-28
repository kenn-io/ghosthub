import GhosthubTmux

enum KwtPowerShellCommand {
    static func resolutionPrelude(
        managedRelativePath: String?
    ) -> String {
        powerShellKwtResolutionPrelude(
            managedRelativePath: managedRelativePath
        )
    }

    static func availabilityPrelude(
        managedRelativePath: String?
    ) -> String {
        powerShellKwtAvailabilityPrelude(
            managedRelativePath: managedRelativePath
        )
    }

    static func run(
        arguments: [String],
        workingDirectory: String? = nil,
        marker: String? = nil,
        managedRelativePath: String?
    ) -> String {
        var lines = [
            "$ErrorActionPreference = 'Stop'",
            "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)",
            "$OutputEncoding = [Console]::OutputEncoding",
            resolutionPrelude(managedRelativePath: managedRelativePath),
        ]
        if let workingDirectory {
            lines.append(
                "Set-Location -LiteralPath "
                    + powerShellEncodedArgument(workingDirectory)
            )
        }
        if let marker {
            lines.append(
                "Write-Output "
                    + powerShellEncodedArgument(marker)
            )
        }
        lines.append(
            "& $ghosthubKwt "
                + arguments
                .map(powerShellEncodedArgument)
                .joined(separator: " ")
        )
        lines.append("exit $LASTEXITCODE")
        return lines.joined(separator: "\n")
    }
}
