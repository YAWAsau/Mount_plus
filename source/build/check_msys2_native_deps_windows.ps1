param(
    [string]$Msys2Root = 'C:\msys64',
    [switch]$InstallPackages,
    [switch]$AutoInstallWinget
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Fail([string]$Message) {
    Write-Host "[ERROR] $Message"
    exit 1
}
function Find-Msys2Root() {
    $candidateRoots = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Msys2Root)) { $candidateRoots.Add($Msys2Root) }
    if ($env:MSYS2_ROOT) { $candidateRoots.Add($env:MSYS2_ROOT) }
    $candidateRoots.Add('C:\msys64')
    $candidateRoots.Add('C:\msys2')
    $candidateRoots.Add('D:\msys64')
    $candidateRoots.Add('D:\msys2')
    $candidateRoots.Add((Join-Path $env:LOCALAPPDATA 'Programs\MSYS2'))

    $seen = @{}
    foreach ($root in $candidateRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try { $fullRoot = [System.IO.Path]::GetFullPath($root) } catch { continue }
        $key = $fullRoot.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $bashPath = Join-Path $fullRoot 'usr\bin\bash.exe'
        $pacmanPath = Join-Path $fullRoot 'usr\bin\pacman.exe'
        if ((Test-Path -LiteralPath $bashPath -PathType Leaf) -and (Test-Path -LiteralPath $pacmanPath -PathType Leaf)) {
            return $fullRoot
        }
    }

    $pathBash = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($pathBash) {
        foreach ($cmd in @($pathBash)) {
            $bashPath = $cmd.Source
            if ($bashPath -match '\\usr\\bin\\bash\.exe$') {
                $rootGuess = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bashPath))
                $pacmanPath = Join-Path $rootGuess 'usr\bin\pacman.exe'
                if (Test-Path -LiteralPath $pacmanPath -PathType Leaf) { return $rootGuess }
            }
        }
    }
    return $null
}
function Run-Step([string]$Title, [string]$Exe, [string[]]$ArgList) {
    Write-Host ""
    Write-Host "[$Title] $Exe $($ArgList -join ' ')"
    & $Exe @ArgList
    if ($LASTEXITCODE -ne 0) { Fail "$Title failed rc=$LASTEXITCODE" }
}
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if ($parent -and (-not (Test-Path -LiteralPath $parent -PathType Container))) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}
function To-MsysPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $drive = $full.Substring(0,1).ToLowerInvariant()
    $rest = $full.Substring(2).Replace('\','/')
    return "/$drive$rest"
}
function Bash-SingleQuote([string]$Text) {
    if ($Text.Contains("'")) { Fail "MSYS2 script path contains a single quote, unsupported: $Text" }
    return "'" + $Text + "'"
}

Write-Host 'YAWAsau MSYS2 native dependency check'
Write-Host "RequestedMsys2Root=$Msys2Root"

$resolvedRoot = Find-Msys2Root
if ((-not $resolvedRoot) -and $AutoInstallWinget) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        Fail @"
MSYS2 is not installed and winget.exe is not available.
Install MSYS2 manually, then rerun this helper with -Msys2Root <your-msys2-root> -InstallPackages.
"@
    }
    Write-Host '[INFO] MSYS2 not found; trying winget install: MSYS2.MSYS2'
    Run-Step -Title 'winget install MSYS2' -Exe $winget.Source -ArgList @('install','--id','MSYS2.MSYS2','-e','--source','winget','--accept-source-agreements','--accept-package-agreements')
    $resolvedRoot = Find-Msys2Root
}

if (-not $resolvedRoot) {
    Fail @"
MSYS2 bash.exe not found.
Checked requested root and common locations: C:\msys64, C:\msys2, D:\msys64, D:\msys2, LocalAppData\Programs\MSYS2, PATH.
Fix:
  1) Install MSYS2, preferably to C:\msys64.
  2) Or rerun with -AutoInstallWinget to let winget try installing MSYS2.MSYS2.
  3) If already installed elsewhere, rerun with -Msys2Root <actual-msys2-root>.
"@
}

$bash = Join-Path $resolvedRoot 'usr\bin\bash.exe'
$pacman = Join-Path $resolvedRoot 'usr\bin\pacman.exe'
if (-not (Test-Path -LiteralPath $bash -PathType Leaf)) { Fail "MSYS2 bash.exe not found after resolve: $bash" }
if (-not (Test-Path -LiteralPath $pacman -PathType Leaf)) { Fail "MSYS2 pacman.exe not found after resolve: $pacman" }

Write-Host "[OK] Msys2Root=$resolvedRoot"
Write-Host "[OK] bash=$bash"
Write-Host "[OK] pacman=$pacman"

if ($InstallPackages) {
    Write-Host '[INFO] installing/updating required MSYS2 packages'
    & $bash -lc 'pacman --needed --noconfirm -Sy pacman pacman-mirrors msys2-runtime bash || true'
    & $bash -lc 'pacman -S --needed --noconfirm meson ninja pkgconf autoconf automake libtool make python git file'
    if ($LASTEXITCODE -ne 0) { Fail "pacman package install failed rc=$LASTEXITCODE" }
}

$checkScript = Join-Path $env:TEMP ("yaw_msys2_tool_check_{0}.sh" -f ([System.Guid]::NewGuid().ToString('N')))
$script = @'
set -eu
missing=""
for x in meson ninja pkg-config autoreconf automake aclocal libtoolize make python git; do
  if ! command -v "$x" >/dev/null 2>&1; then
    missing="$missing $x"
  fi
done
if [ -n "$missing" ]; then
  echo "$missing"
  exit 9
fi
'@
Write-Utf8NoBom -Path $checkScript -Text $script
$cmd = 'bash ' + (Bash-SingleQuote (To-MsysPath $checkScript))
$output = & $bash -lc $cmd 2>&1
$rc = $LASTEXITCODE
foreach ($line in $output) { Write-Host ($line.ToString()) }
try { Remove-Item -LiteralPath $checkScript -Force -ErrorAction SilentlyContinue } catch { }
if ($rc -ne 0) {
    $missing = (($output | ForEach-Object { $_.ToString() }) -join ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($missing)) { $missing = 'unknown' }
    Fail "Missing tools or check failed:$missing. Rerun with -InstallPackages."
}

Write-Host '[OK] MSYS2 native build dependencies are ready'
