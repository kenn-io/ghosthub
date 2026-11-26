import Foundation

public func shellQuotedCommandArgument(_ value: String) -> String {
    "'" + value.unicodeScalars.map { $0 == "'" ? "'\\''" : String($0) }.joined() + "'"
}

private func accountShellCommandArgument(_ value: String) -> String {
    // Shell syntax operates on bytes, not extended grapheme clusters.
    value.utf8.split(separator: 0x60, omittingEmptySubsequences: false)
        .map { segment in
            let escaped = String(decoding: segment, as: UTF8.self).unicodeScalars.map {
                switch $0 {
                case "\\", "\"", "$": "\\" + String($0)
                default: String($0)
                }
            }.joined()
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

/// Package-manager binary directories that interactive startup files such as
/// `~/.zshrc` often put on PATH. A login shell that is not interactive skips
/// those files, so commands Ghosthub runs would miss Homebrew's tmux.
private let loginPathFallbackDirectories = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/opt/local/bin",
    "/home/linuxbrew/.linuxbrew/bin",
    "$HOME/.nix-profile/bin",
    "/run/current-system/sw/bin",
]

/// Appends each existing fallback directory missing from PATH, after the
/// login shell has initialized it, so the account's own PATH order wins.
private let loginPathFallbackPrelude =
    "for ghosthub_path_dir in "
        + loginPathFallbackDirectories.map { "\"\($0)\"" }
        .joined(separator: " ")
        + "; do case \":$PATH:\" in *\":$ghosthub_path_dir:\"*) ;; "
        + "*) if [ -d \"$ghosthub_path_dir\" ]; then "
        + "PATH=\"${PATH:+$PATH:}$ghosthub_path_dir\"; fi ;; esac; done; "
        + "unset ghosthub_path_dir; export PATH; "

/// Runs a POSIX command under `/bin/sh` inside an already-started account
/// login shell, with package-manager PATH fallbacks applied.
public func postLoginShellCommand(_ command: String) -> String {
    accountShellCommand(loginPathFallbackPrelude + command)
}

private func accountLoginCommand(_ command: String) -> String {
    let posixCommand = postLoginShellCommand(command)
    return "exec \"${SHELL:-/bin/sh}\" -lc "
        + shellQuotedCommandArgument(posixCommand)
}

public func accountLoginShellCommand(_ command: String) -> String {
    accountShellCommand(accountLoginCommand(command))
}

public func surfaceAccountLoginShellCommand(_ command: String) -> String {
    "/bin/sh -c " + accountShellCommandArgument(accountLoginCommand(command))
}
