param(
    [string]$MagiskSrc = '',
    [string]$Ref = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
if ([string]::IsNullOrWhiteSpace($MagiskSrc)) { $MagiskSrc = Join-Path $RootDir 'third_party\Magisk' }

function Fail([string]$m) { Write-Host "[ERROR] $m"; exit 1 }
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { Fail 'git not found in PATH. Install Git for Windows and enable symbolic links/developer mode as required by Magisk.' }

function Run-GitChecked {
    param([string]$Title, [Alias('Args')][string[]]$GitArgs)
    Write-Host ("[git] {0}: git {1}" -f $Title, ($GitArgs -join ' '))
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) { Fail "$Title failed" }
}

function Enable-GitSymlinkCheckout {
    # Magisk's cxx-rs submodule is built from a git checkout on Windows. Its
    # build.rs requires real symlinks. Developer Mode grants the OS right, but
    # Git also has to be told to checkout symlinks instead of placeholder files.
    Write-Host '[INFO] enabling Git symlink checkout: core.symlinks=true'
    Run-GitChecked -Title 'git config global core.symlinks' -GitArgs @('config','--global','core.symlinks','true')
}

function Repair-MagiskSubmoduleSymlinks {
    param([string]$Repo)
    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) { return }
    Push-Location $Repo
    try {
        Run-GitChecked -Title 'Magisk local core.symlinks' -GitArgs @('config','core.symlinks','true')
        Run-GitChecked -Title 'Magisk submodule local core.symlinks' -GitArgs @('-c','core.symlinks=true','submodule','foreach','--recursive','git config core.symlinks true')
        Run-GitChecked -Title 'Magisk submodule update with symlinks' -GitArgs @('-c','core.symlinks=true','submodule','update','--init','--recursive','--force')
        Run-GitChecked -Title 'Magisk checkout symlink repair' -GitArgs @('-c','core.symlinks=true','reset','--hard')
        Run-GitChecked -Title 'Magisk submodule checkout symlink repair' -GitArgs @('-c','core.symlinks=true','submodule','foreach','--recursive','git reset --hard')
    } finally { Pop-Location }
}

Enable-GitSymlinkCheckout

if ((Test-Path -LiteralPath $MagiskSrc) -and $Force) {
    Remove-Item -LiteralPath $MagiskSrc -Recurse -Force
}

if (-not (Test-Path -LiteralPath $MagiskSrc -PathType Container)) {
    $parent = Split-Path -Parent $MagiskSrc
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Write-Host "[INFO] cloning official Magisk source to $MagiskSrc"
    Run-GitChecked -Title 'git clone official Magisk source with symlinks' -GitArgs @('-c','core.symlinks=true','clone','-c','core.symlinks=true','--recurse-submodules','https://github.com/topjohnwu/Magisk.git',$MagiskSrc)
    Repair-MagiskSubmoduleSymlinks -Repo $MagiskSrc
} else {
    Write-Host "[INFO] updating official Magisk source at $MagiskSrc"
    Push-Location $MagiskSrc
    try {
        Run-GitChecked -Title 'git fetch official Magisk source' -GitArgs @('-c','core.symlinks=true','fetch','--tags','--recurse-submodules')
        Repair-MagiskSubmoduleSymlinks -Repo $MagiskSrc
    } finally { Pop-Location }
}

if (-not [string]::IsNullOrWhiteSpace($Ref)) {
    Push-Location $MagiskSrc
    try {
        Run-GitChecked -Title "git checkout Magisk ref $Ref" -GitArgs @('-c','core.symlinks=true','checkout',$Ref)
        Repair-MagiskSubmoduleSymlinks -Repo $MagiskSrc
    } finally { Pop-Location }
}

Write-Host '[OK] official Magisk source ready'
Write-Host "MagiskSrc=$MagiskSrc"
