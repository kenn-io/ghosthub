param(
    [ValidateSet("amd64", "arm64")]
    [string]$Architecture = $(
        if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
    )
)

$ErrorActionPreference = "Stop"

function Assert-NativeSuccess {
    param(
        [Parameter(Mandatory)]
        [string]$Action,
        [Parameter(Mandatory)]
        [int]$ExitCode
    )
    if ($ExitCode -ne 0) {
        throw "$Action failed with exit code $ExitCode"
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$revision = (Get-Content -Raw (Join-Path $repoRoot "KWT_REVISION")).Trim()
if ($revision -notmatch '^[0-9a-f]{40}$') {
    throw "KWT_REVISION must contain one lowercase 40-character Git revision"
}

$source = Join-Path $repoRoot ".build\kwt-source"
$variantsDirectory = Join-Path $repoRoot ".build\kwt\variants"

if (-not (Test-Path (Join-Path $source ".git"))) {
    git clone --filter=blob:none https://github.com/kenn-io/kwt.git $source
    Assert-NativeSuccess "clone KWT source" $LASTEXITCODE
}
$dirty = @(git -C $source status --porcelain --untracked-files=all)
Assert-NativeSuccess "inspect KWT source checkout" $LASTEXITCODE
if ($dirty.Count -ne 0) {
    throw "KWT source checkout has uncommitted or untracked changes; refusing to build"
}
git -C $source fetch origin $revision
Assert-NativeSuccess "fetch pinned KWT revision" $LASTEXITCODE
git -C $source checkout --detach $revision
Assert-NativeSuccess "check out pinned KWT revision" $LASTEXITCODE
$resolvedRevision = (git -C $source rev-parse HEAD).Trim()
Assert-NativeSuccess "resolve KWT source revision" $LASTEXITCODE
if ($resolvedRevision -ne $revision) {
    throw "KWT source checkout does not match KWT_REVISION"
}
$dirty = @(git -C $source status --porcelain --untracked-files=all)
Assert-NativeSuccess "verify pinned KWT source checkout" $LASTEXITCODE
if ($dirty.Count -ne 0) {
    throw "KWT source checkout changed while selecting the pinned revision"
}

$previousGoos = $env:GOOS
$previousGoarch = $env:GOARCH
$previousCgo = $env:CGO_ENABLED
try {
    $env:GOARCH = $Architecture
    $env:CGO_ENABLED = "0"
    foreach ($targetOs in @("linux", "windows")) {
        $target = "$targetOs-$Architecture"
        $outputDirectory = Join-Path $variantsDirectory $target
        $output = Join-Path $outputDirectory "kwt"
        New-Item -ItemType Directory -Force $outputDirectory | Out-Null
        Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
        $env:GOOS = $targetOs
        Push-Location $source
        try {
            go build -trimpath `
                -ldflags "-s -w -X go.kenn.io/kwt/internal/cmd.version=$revision" `
                -o $output `
                cmd/kwt/main.go
            if ($LASTEXITCODE -ne 0) {
                Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
                throw "build pinned KWT helper for $target failed with exit code $LASTEXITCODE"
            }
        }
        finally {
            Pop-Location
        }
        if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
            throw "KWT build did not produce an executable for $target"
        }
        uv run --frozen python (Join-Path $repoRoot "tools\validate_kwt_variants.py") `
            --variants-dir $variantsDirectory `
            --revision $revision `
            --target $target
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
            throw "validate pinned KWT helper for $target failed with exit code $LASTEXITCODE"
        }

        $digest = (Get-FileHash -Algorithm SHA256 $output).Hash.ToLowerInvariant()
        Write-Output "Built pinned KWT $revision for $target"
        Write-Output "Path: $output"
        Write-Output "SHA-256: $digest"
    }
}
finally {
    $env:GOOS = $previousGoos
    $env:GOARCH = $previousGoarch
    $env:CGO_ENABLED = $previousCgo
}
