import GhosthubTmux

enum KwtPowerShellCommand {
    static var resolutionPrelude: String {
        powerShellKwtResolutionPrelude()
    }

    static var availabilityPrelude: String {
        powerShellKwtAvailabilityPrelude()
    }

    static func run(
        arguments: [String],
        workingDirectory: String? = nil,
        marker: String? = nil
    ) -> String {
        var lines = [
            "$ErrorActionPreference = 'Stop'",
            "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)",
            "$OutputEncoding = [Console]::OutputEncoding",
            resolutionPrelude,
        ]
        if let workingDirectory {
            lines.append(
                "Set-Location -LiteralPath "
                    + powerShellQuotedCommandArgument(workingDirectory)
            )
        }
        if let marker {
            lines.append(
                "Write-Output "
                    + powerShellQuotedCommandArgument(marker)
            )
        }
        lines.append(
            "& $ghosthubKwt "
                + arguments
                .map(powerShellQuotedCommandArgument)
                .joined(separator: " ")
        )
        lines.append("exit $LASTEXITCODE")
        return lines.joined(separator: "\n")
    }
}
