import Foundation

public func shellQuotedCommandArgument(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func accountShellCommandArgument(_ value: String) -> String {
    value.split(separator: "`", omittingEmptySubsequences: false)
        .map { segment in
            let escaped = String(segment)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
            return "\"\(escaped)\""
        }
        .joined(separator: "'`'")
}

public func accountShellCommand(_ command: String) -> String {
    "exec /bin/sh -c " + accountShellCommandArgument(command)
}

public func powerShellEncodedArgument(_ value: String) -> String {
    let encoded = Data(value.utf8).base64EncodedString()
    return "([System.Text.Encoding]::UTF8.GetString("
        + "[System.Convert]::FromBase64String('\(encoded)')))"
}

public func powerShellEncodedCommand(_ command: String) -> String {
    let data = command.data(using: .utf16LittleEndian) ?? Data()
    return [
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-EncodedCommand",
        data.base64EncodedString(),
    ].joined(separator: " ")
}

public func powerShellKwtResolutionPrelude(
    managedRelativePath: String?
) -> String {
    guard let managedRelativePath else {
        return "throw 'Ghosthub managed kwt is unavailable'"
    }
    return """
    $ghosthubKwt = Join-Path $env:USERPROFILE \(
        powerShellEncodedArgument(managedRelativePath)
    )
    if (-not (Test-Path -LiteralPath $ghosthubKwt -PathType Leaf)) {
        throw 'Ghosthub managed kwt is unavailable'
    }
    """
}

public func powerShellKwtAvailabilityPrelude(
    managedRelativePath: String?
) -> String {
    guard let managedRelativePath else {
        return "$ghosthubKwtAvailable = $false"
    }
    return """
    $ghosthubManagedKwt = Join-Path $env:USERPROFILE \(
        powerShellEncodedArgument(managedRelativePath)
    )
    $ghosthubKwtAvailable = Test-Path -LiteralPath $ghosthubManagedKwt -PathType Leaf
    """
}

private func accountLoginCommand(_ command: String) -> String {
    let posixCommand = accountShellCommand(command)
    return "exec \"${SHELL:-/bin/sh}\" -lc "
        + shellQuotedCommandArgument(posixCommand)
}

public func accountLoginShellCommand(_ command: String) -> String {
    accountShellCommand(accountLoginCommand(command))
}

public func surfaceAccountLoginShellCommand(_ command: String) -> String {
    "/bin/sh -c " + accountShellCommandArgument(accountLoginCommand(command))
}
