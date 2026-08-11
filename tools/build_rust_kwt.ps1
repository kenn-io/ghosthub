param(
    [ValidateSet("amd64", "arm64")]
    [string]$Architecture = $(
        if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
    )
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$revision = (Get-Content -Raw (Join-Path $repoRoot "KWT_REVISION")).Trim()
if ($revision -notmatch '^[0-9a-f]{40}$') {
    throw "KWT_REVISION must contain one lowercase 40-character Git revision"
}

$source = Join-Path $repoRoot ".build\kwt-source"
$outputDirectory = Join-Path $repoRoot ".build\kwt\variants\linux-$Architecture"
$output = Join-Path $outputDirectory "kwt"

if (-not (Test-Path (Join-Path $source ".git"))) {
    git clone --filter=blob:none https://github.com/kenn-io/kwt.git $source
}
git -C $source fetch origin $revision
git -C $source checkout --detach $revision
if ((git -C $source rev-parse HEAD).Trim() -ne $revision) {
    throw "KWT source checkout does not match KWT_REVISION"
}

New-Item -ItemType Directory -Force $outputDirectory | Out-Null
$previousGoos = $env:GOOS
$previousGoarch = $env:GOARCH
$previousCgo = $env:CGO_ENABLED
try {
    $env:GOOS = "linux"
    $env:GOARCH = $Architecture
    $env:CGO_ENABLED = "0"
    Push-Location $source
    try {
        go build -trimpath `
            -ldflags "-s -w -X go.kenn.io/kwt/internal/cmd.version=$revision" `
            -o $output `
            cmd/kwt/main.go
    }
    finally {
        Pop-Location
    }
}
finally {
    $env:GOOS = $previousGoos
    $env:GOARCH = $previousGoarch
    $env:CGO_ENABLED = $previousCgo
}

$digest = (Get-FileHash -Algorithm SHA256 $output).Hash.ToLowerInvariant()
Write-Output "Built pinned KWT $revision for linux-$Architecture"
Write-Output "Path: $output"
Write-Output "SHA-256: $digest"
