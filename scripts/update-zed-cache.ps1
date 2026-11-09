#Requires -Version 5.1
<#
.SYNOPSIS
Updates the Zed npx cache with the ACP-patched Kimi Code bundle.

.DESCRIPTION
Downloads the Windows cache asset from a v<version>-patched GitHub release,
validates it, and atomically replaces the Zed npx cache directory. The
previous tree is removed after a successful swap.

.PARAMETER Tag
Release tag. Defaults to the newest v<version>-patched release.

.PARAMETER DryRun
Download and validate without replacing the cache.

.PARAMETER Repo
GitHub repository. Defaults to $env:KIMI_CODE_REPO or luckzylp/kimi-code.

.PARAMETER CacheDir
Target cache directory. Defaults to $env:KIMI_CODE_ZED_CACHE_DIR or
%LOCALAPPDATA%\Zed\external_agents\registry\npx\kimi-code.

.PARAMETER BaseUrl
Override the release asset base URL. Defaults to
$env:KIMI_CODE_ZED_CACHE_BASE_URL or the GitHub release URL.

.EXAMPLE
.\scripts\update-zed-cache.ps1

.EXAMPLE
.\scripts\update-zed-cache.ps1 -DryRun -Tag v2.5.2-patched
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [switch]$DryRun,
    [string]$Repo,
    [string]$CacheDir,
    [string]$BaseUrl
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Fail([string]$Message) {
    throw "error: $Message"
}

if ($env:OS -ne 'Windows_NT') {
    Fail 'this script supports Windows only'
}

if (-not $Repo) {
    $Repo = if ($env:KIMI_CODE_REPO) { $env:KIMI_CODE_REPO } else { 'luckzylp/kimi-code' }
}
if (-not $CacheDir) {
    if (-not $env:LOCALAPPDATA) {
        Fail 'LOCALAPPDATA is not set; pass -CacheDir'
    }
    $CacheDir = Join-Path $env:LOCALAPPDATA 'Zed\external_agents\registry\npx\kimi-code'
}
$CacheDir = [System.IO.Path]::GetFullPath($CacheDir)
$Root = Split-Path -Parent $CacheDir
New-Item -ItemType Directory -Force -Path $Root | Out-Null

$lock = $null
$Tmp = $null
try {
    $lockPath = Join-Path $Root '.kimi-zed-cache.lock'
    try {
        $lock = [System.IO.File]::Open(
            $lockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        Fail 'another update is already running'
    }

    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Fail 'node is not on PATH (Node.js >= 22.19 is required)'
    }
    $nodeVersion = (& node -p "process.versions.node").Trim()
    $nodeParts = $nodeVersion.Split('.') | ForEach-Object { [int]$_ }
    if ($nodeParts[0] -lt 22 -or ($nodeParts[0] -eq 22 -and $nodeParts[1] -lt 19)) {
        Fail "Node.js >= 22.19 is required (found $nodeVersion)"
    }

    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    switch ($architecture) {
        'X64' { $Target = 'win32-x64' }
        'Arm64' { $Target = 'win32-arm64' }
        default { Fail "unsupported architecture: $architecture" }
    }

    if (-not $Tag) {
        $headers = @{
            'User-Agent' = 'kimi-code-zed-cache-updater'
            'Accept' = 'application/vnd.github+json'
        }
        if ($env:GITHUB_TOKEN) {
            $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
        }
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=30" -Headers $headers
        $Tag = $releases |
            Where-Object { $_.tag_name -match '^v\d+\.\d+\.\d+-patched$' } |
            Sort-Object { [version](($_.tag_name -replace '^v', '') -replace '-patched$', '') } |
            Select-Object -Last 1 -ExpandProperty tag_name
        if (-not $Tag) {
            Fail 'could not resolve the latest v<version>-patched release'
        }
    }

    if ($Tag -match '^v(\d+)\.(\d+)\.(\d+)-patched$') {
        $Version = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
    } else {
        Fail "unsupported tag: $Tag"
    }

    if (-not $BaseUrl) {
        $BaseUrl = "https://github.com/$Repo/releases/download/$Tag"
    }

    $Asset = "kimi-code-zed-cache-$Target-$Version-patched.zip"
    $Manifest = "kimi-code-zed-cache-$Target.json"

    $Tmp = Join-Path $Root ('.kimi-zed-cache-update.' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Tmp | Out-Null

    Write-Host "==> downloading $Tag ($Target)"
    $zip = Join-Path $Tmp $Asset
    $shaFile = "$zip.sha256"

    try {
        Invoke-WebRequest -Uri "$BaseUrl/$Asset" -OutFile $zip -UseBasicParsing
    } catch {
        Fail "cache asset not found: $BaseUrl/$Asset (run the Zed cache workflow first)"
    }
    try {
        Invoke-WebRequest -Uri "$BaseUrl/$Asset.sha256" -OutFile $shaFile -UseBasicParsing
    } catch {
        Fail "checksum not found: $BaseUrl/$Asset.sha256"
    }

    $actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLowerInvariant()
    $expected = ((Get-Content -Path $shaFile -Raw) -split '\s+')[0].ToLowerInvariant()
    if ($actual -ne $expected) {
        Fail "sha256 mismatch: expected $expected, got $actual"
    }

    $manifestPath = Join-Path $Tmp 'manifest.json'
    try {
        Invoke-WebRequest -Uri "$BaseUrl/$Manifest" -OutFile $manifestPath -UseBasicParsing
    } catch {
        # The manifest is optional.
    }
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        } catch {
            $manifest = $null
        }
        if ($manifest) {
            $mismatch = $manifest.upstreamVersion -ne $Version
            $mismatch = $mismatch -or ($manifest.asset -ne $Asset)
            $mismatch = $mismatch -or ($manifest.sha256 -ne $actual)
            if ($mismatch) {
                Fail 'manifest does not match the downloaded asset'
            }
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            if ($name -match '^(\./)?npx[\\/]?$') {
                continue
            }
            if ($name -notmatch '^(\./)?npx[\\/]kimi-code([\\/]|$)') {
                Fail "archive contains a path outside npx/kimi-code: $name"
            }
        }
    } finally {
        $archive.Dispose()
    }

    $extract = Join-Path $Tmp 'extract'
    New-Item -ItemType Directory -Path $extract | Out-Null
    Expand-Archive -Path $zip -DestinationPath $extract -Force

    $New = Join-Path $extract 'npx\kimi-code'
    $pkgJson = Join-Path $New 'package.json'
    $pkgLock = Join-Path $New 'package-lock.json'
    $hiddenLock = Join-Path $New 'node_modules\.package-lock.json'
    $main = Join-Path $New 'node_modules\@moonshot-ai\kimi-code\dist\main.mjs'
    $binCmd = Join-Path $New 'node_modules\.bin\kimi.cmd'

    foreach ($path in @($pkgJson, $pkgLock, $hiddenLock, $main, $binCmd)) {
        if (-not (Test-Path -LiteralPath $path)) {
            Fail "cache entry missing: $path"
        }
    }

    $spec = (Get-Content -LiteralPath $pkgJson -Raw | ConvertFrom-Json).dependencies.'@moonshot-ai/kimi-code'
    if ($spec -ne $Version) {
        Fail "cache is for $spec, expected $Version"
    }

    $installedVersion = (Get-Content -LiteralPath (Join-Path $New 'node_modules\@moonshot-ai\kimi-code\package.json') -Raw | ConvertFrom-Json).version
    if ($installedVersion -ne $Version) {
        Fail "cache package is $installedVersion, expected $Version"
    }

    & node --check $main
    if ($LASTEXITCODE -ne 0) {
        Fail 'main.mjs failed node --check'
    }

    foreach ($marker in @('MIN_ASSISTANT_CHUNK_CHARS', 'shouldServeLocally', 'commandTextFromBlocks', 'scheduleUsageUpdate')) {
        if (-not (Select-String -LiteralPath $main -Pattern $marker -Quiet)) {
            Fail "patched bundle is missing $marker"
        }
    }

    $oldHome = $env:KIMI_CODE_HOME
    $env:KIMI_CODE_HOME = Join-Path $Tmp 'home'
    New-Item -ItemType Directory -Force -Path $env:KIMI_CODE_HOME | Out-Null
    try {
        & node $main --version | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail 'main.mjs --version failed'
        }
        & node $main acp --help | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Fail 'main.mjs acp --help failed'
        }
    } finally {
        if ($null -eq $oldHome) {
            Remove-Item Env:KIMI_CODE_HOME -ErrorAction SilentlyContinue
        } else {
            $env:KIMI_CODE_HOME = $oldHome
        }
    }

    $existingPkg = Join-Path $CacheDir 'package.json'
    if (Test-Path -LiteralPath $existingPkg) {
        $current = (Get-Content -LiteralPath $existingPkg -Raw | ConvertFrom-Json).dependencies.'@moonshot-ai/kimi-code'
        if ($current -and $current -ne $Version) {
            Fail "Zed cache expects $current; refusing to install $Version (rebase the patches first)"
        }
    }

    if ($DryRun) {
        Write-Host "dry run: would install $Tag ($Version) into $CacheDir"
        return
    }

    $old = $null
    $installed = $false
    try {
        if (Test-Path -LiteralPath $CacheDir) {
            $old = Join-Path $Root ('.kimi-zed-cache.old.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID)
            Move-Item -LiteralPath $CacheDir -Destination $old
        }
        Move-Item -LiteralPath $New -Destination $CacheDir
        $installed = $true
    } finally {
        if (-not $installed -and $old -and -not (Test-Path -LiteralPath $CacheDir) -and (Test-Path -LiteralPath $old)) {
            Move-Item -LiteralPath $old -Destination $CacheDir
        }
    }
    if ($old) {
        Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "updated $CacheDir"
    Write-Host "  release: $Tag"
    Write-Host "  version: $Version"
    Write-Host "  sha256:  $actual"

    $settings = Join-Path $env:APPDATA 'Zed\settings.json'
    if (-not (Test-Path -LiteralPath $settings) -or -not (Select-String -LiteralPath $settings -Pattern '"kimi-code"' -Quiet)) {
        Write-Host ''
        Write-Host "note: $settings has no `"kimi-code`" agent entry."
    }
    Write-Host ''
    Write-Host 'Restart the kimi-code agent in Zed to load the new build.'
} finally {
    if ($Tmp -and (Test-Path -LiteralPath $Tmp)) {
        Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($lock) {
        $lock.Dispose()
    }
}
