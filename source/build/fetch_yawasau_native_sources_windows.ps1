param(
    [string]$ThirdPartyRoot = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
Set-Location $RootDir

if ([string]::IsNullOrWhiteSpace($ThirdPartyRoot)) {
    $ThirdPartyRoot = Join-Path $RootDir 'third_party'
} else {
    $ThirdPartyRoot = [System.IO.Path]::GetFullPath($ThirdPartyRoot)
}
New-Item -ItemType Directory -Force -Path $ThirdPartyRoot | Out-Null

function Fetch-And-Extract {
    param(
        [string]$Name,
        [string]$Url,
        [string]$DirName,
        [string]$ExpectedSha256
    )
    $dir = Join-Path $ThirdPartyRoot $DirName
    $archive = Join-Path $ThirdPartyRoot ($DirName + '.tar.gz')
    if ((Test-Path -LiteralPath $dir -PathType Container) -and -not $Force) {
        Write-Host "[OK] $Name source exists: $dir"
        if (Test-Path -LiteralPath $archive -PathType Leaf) {
            $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
            if ($existingHash -ne $ExpectedSha256.ToLowerInvariant()) {
                throw "$Name archive SHA256 mismatch: expected=$ExpectedSha256 actual=$existingHash archive=$archive"
            }
            Write-Host "[SHA256-OK] $existingHash  $([System.IO.Path]::GetFileName($archive))"
        }
        return
    }
    if ($Force -and (Test-Path -LiteralPath $dir)) { Remove-Item -LiteralPath $dir -Recurse -Force }
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf) -or $Force) {
        Write-Host "[DOWNLOAD] $Name source: $Url"
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $archive
    } else {
        Write-Host "[OK] using existing archive: $archive"
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
    if ($hash -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "$Name archive SHA256 mismatch: expected=$ExpectedSha256 actual=$hash archive=$archive"
    }
    Write-Host "[SHA256-OK] $hash  $([System.IO.Path]::GetFileName($archive))"
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if (-not $tar) { throw "Windows tar not found. Extract $archive manually into $ThirdPartyRoot" }
    Write-Host "[EXTRACT] $archive"
    & $tar.Source -xzf $archive -C $ThirdPartyRoot
    if ($LASTEXITCODE -ne 0) { throw "tar failed rc=$LASTEXITCODE archive=$archive" }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "expected source directory missing after extract: $dir" }
}

Fetch-And-Extract `
    -Name 'libfuse' `
    -Url 'https://github.com/libfuse/libfuse/archive/refs/tags/fuse-3.18.2.tar.gz' `
    -DirName 'libfuse-fuse-3.18.2' `
    -ExpectedSha256 '55a97cfd8661a9b42ff0123b44af52cac49feaec36987f4d968c046f93b42e1d'

Fetch-And-Extract `
    -Name 'bindfs' `
    -Url 'https://bindfs.org/downloads/bindfs-1.18.4.tar.gz' `
    -DirName 'bindfs-1.18.4' `
    -ExpectedSha256 '3266d0aab787a9328bbb0ed561a371e19f1ff077273e6684ca92a90fedb2fe24'

Get-ChildItem -LiteralPath $ThirdPartyRoot -Filter '*.tar.gz' -File | ForEach-Object {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
    "$hash  $($_.Name)"
} | Sort-Object | Set-Content -LiteralPath (Join-Path $ThirdPartyRoot 'SHA256SUMS_DOWNLOADED_SOURCES.txt') -Encoding ASCII

Write-Host '[OK] source fetch completed'
Write-Host "ThirdPartyRoot=$ThirdPartyRoot"
