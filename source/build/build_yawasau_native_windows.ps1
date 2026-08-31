param(
    [int]$Api = 28,
    [string]$NdkVersion = '28.2.13676358',
    [string]$NdkRoot = '',
    [string]$Msys2Root = 'C:\msys64',
    [string]$WorkDir = 'native_work',
    [string]$OutDir = 'native_out',
    [string]$LibfuseSrc = '',
    [string]$BindfsSrc = '',
    [string]$MagiskSrc = '',
    [string]$MagiskRef = '',
    [string]$MagiskAbi = 'arm64-v8a',
    [string]$Python = 'auto',
    [switch]$SetupMagiskNdk,
    [switch]$IncludeMagiskPolicy,
    [string]$ThirdPartyRoot = '',
    [ValidateSet(4096,16384)][int]$PageSize = 16384,
    [switch]$BuildMagiskPolicy,
    [switch]$NoBuildMagiskPolicy,
    [switch]$NoSetupMagiskNdk,
    [switch]$NoIncludeMagiskPolicy,
    [switch]$NoPackModule,
    [switch]$SkipBindfs,
    [switch]$NoFetchSources,
    [switch]$NoFetchMagisk,
    [switch]$AutoInstallMsys2,
    [switch]$KeepWork,
    [switch]$PackModule,
    [string]$ModuleZipOut = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
Set-Location $RootDir

$LogPath = Join-Path $ScriptDir 'build_yawasau_native_windows.log'
if (Test-Path -LiteralPath $LogPath) { Remove-Item -LiteralPath $LogPath -Force }

# v1.4.72: native source restored; for notification builds prefer build_yawasau_full_module_windows.ps1 so classes.dex is packaged. A plain
#   .\build_yawasau_native_windows.ps1
# builds static bindfs/libfuse3 and native mount.fuse3 helper, then reuses the bundled
# known-good magiskpolicy unless -BuildMagiskPolicy is explicitly supplied. This avoids
# repeatedly cloning Magisk/downloading ONDK for ordinary module rebuilds.
if ($NoBuildMagiskPolicy) { $BuildMagiskPolicy = $false }
if (-not $NoSetupMagiskNdk) { $SetupMagiskNdk = $true }
if (-not $NoIncludeMagiskPolicy) { $IncludeMagiskPolicy = $true }
if (-not $NoPackModule) { $PackModule = $true }

function Log([string]$Message = '') {
    Write-Host $Message
    Add-Content -LiteralPath $LogPath -Value $Message -Encoding UTF8
}
function Fail([string]$Message) {
    Log "[ERROR] $Message"
    Log "[ERROR] build log saved: $LogPath"
    exit 1
}
function Need-File([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Fail "$Name not found: $Path" }
}
function Need-Dir([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Fail "$Name not found: $Path" }
}
function Run-Checked {
    param([string]$Title, [string]$Exe, [string[]]$ArgList)
    Log ''
    Log "[$Title] $Exe $($ArgList -join ' ')"
    # Windows PowerShell 5.1 turns native stderr records into NativeCommandError
    # when $ErrorActionPreference is Stop, even if stderr is redirected with 2>&1.
    # v1.4.21 aborted at the first clang diagnostic line and hid the real compile
    # error. Temporarily downgrade EAP only for native process streaming, then
    # decide success/failure from the child exit code.
    $oldEap = $ErrorActionPreference
    $oldNativePrefExists = $false
    $oldNativePref = $null
    try {
        $var = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
        if ($var) {
            $oldNativePrefExists = $true
            $oldNativePref = $var.Value
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope 1 -ErrorAction SilentlyContinue
        }
    } catch { }
    try {
        $ErrorActionPreference = 'Continue'
        & $Exe @ArgList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                if ($_.Exception -and $_.Exception.Message) { Log ($_.Exception.Message) }
                else { Log ($_.ToString()) }
            } else {
                Log ($_.ToString())
            }
        }
        $rc = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
        if ($oldNativePrefExists) {
            try { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $oldNativePref -Scope 1 -ErrorAction SilentlyContinue } catch { }
        }
    }
    if ($rc -ne 0) { Fail "$Title failed rc=$rc" }
}
function Find-SdkRoot() {
    if ($env:ANDROID_SDK_ROOT) { return $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { return $env:ANDROID_HOME }
    return (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
}
function Resolve-NdkRoot() {
    if (-not [string]::IsNullOrWhiteSpace($NdkRoot)) { return [System.IO.Path]::GetFullPath($NdkRoot) }
    $sdk = Find-SdkRoot
    return (Join-Path $sdk "ndk\$NdkVersion")
}
function Resolve-SdkRootFromNdk([string]$ResolvedNdk) {
    # Magisk upstream build.py requires ANDROID_HOME. Users already provide NDK
    # version/root, so derive the SDK root from ...\Android\Sdk\ndk\<ver>
    # when ANDROID_HOME/ANDROID_SDK_ROOT is not already exported.
    if ($env:ANDROID_HOME) { return [System.IO.Path]::GetFullPath($env:ANDROID_HOME) }
    if ($env:ANDROID_SDK_ROOT) { return [System.IO.Path]::GetFullPath($env:ANDROID_SDK_ROOT) }
    $fullNdk = [System.IO.Path]::GetFullPath($ResolvedNdk)
    $parent = Split-Path -Parent $fullNdk
    if ((Split-Path -Leaf $parent) -ieq 'ndk') {
        return (Split-Path -Parent $parent)
    }
    # Fallback to the normal Android Studio SDK path if a custom NDK root was used.
    return [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Android\Sdk'))
}
function Set-AndroidSdkEnvForChildTools([string]$SdkRoot) {
    if ([string]::IsNullOrWhiteSpace($SdkRoot)) { Fail 'Unable to resolve Android SDK root for Magisk build.py' }
    if (-not (Test-Path -LiteralPath $SdkRoot -PathType Container)) { Fail "Android SDK root not found: $SdkRoot" }
    $env:ANDROID_HOME = $SdkRoot
    $env:ANDROID_SDK_ROOT = $SdkRoot
    Log "[INFO] Android SDK env for child tools: ANDROID_HOME=$SdkRoot"
}

function Resolve-PythonSpec {
    param([string]$RequestedPython)
    function _TestPy([string]$Exe, [string[]]$PrefixArgs) {
        try {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $out = & $Exe @PrefixArgs --version 2>&1
            $rc = $LASTEXITCODE
            $ErrorActionPreference = $oldEap
            if ($rc -eq 0) {
                return [PSCustomObject]@{ Exe = $Exe; PrefixArgs = $PrefixArgs; Version = ($out -join ' ') }
            }
        } catch {
            try { $ErrorActionPreference = $oldEap } catch { }
        }
        return $null
    }

    $req = if ($RequestedPython) { $RequestedPython.Trim() } else { '' }
    if ($req.Length -gt 0 -and $req -ne 'auto' -and $req -ne 'python') {
        # Explicit user choice. Support both "py" and full python.exe paths.
        if ($req -ieq 'py' -or $req -ieq 'py.exe') {
            $r = _TestPy $req @('-3')
            if ($r) { return $r }
        }
        $r = _TestPy $req @()
        if ($r) { return $r }
        Fail "Python command not usable: $req. Install Python 3 and ensure it is on PATH, or pass -Python py after installing the Python launcher."
    }

    # Default auto-detection for Windows PowerShell 5.1: the Python launcher is
    # often present as `py` even when `python` is not on PATH. rc=9009 from
    # `python build.py ndk` means the command was not found, not a Magisk error.
    foreach ($cand in @(@('python', @()), @('py', @('-3')), @('python3', @()))) {
        $exe = [string]$cand[0]
        $pre = [string[]]$cand[1]
        $r = _TestPy $exe $pre
        if ($r) { return $r }
    }
    Fail 'Python 3 not found. Install Python 3.x and enable "Add python.exe to PATH", or install the Python launcher and rerun with -Python py.'
}



function Ensure-MagiskGitSymlinkCheckout {
    param([string]$Repo)
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) { Fail 'git not found in PATH. Official Magisk source build requires Git for Windows.' }
    if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) {
        Log "[WARN] Magisk source is not a git checkout; cannot repair cxx-rs symlinks: $Repo"
        return
    }
    Log '[INFO] ensuring Git symlink checkout for official Magisk/cxx-rs source: core.symlinks=true'
    Run-Checked -Title 'git config global core.symlinks' -Exe 'git' -ArgList @('config','--global','core.symlinks','true')
    Push-Location $Repo
    try {
        Run-Checked -Title 'Magisk local core.symlinks' -Exe 'git' -ArgList @('config','core.symlinks','true')
        Run-Checked -Title 'Magisk submodule local core.symlinks' -Exe 'git' -ArgList @('-c','core.symlinks=true','submodule','foreach','--recursive','git config core.symlinks true')
        Run-Checked -Title 'Magisk submodule update with symlinks' -Exe 'git' -ArgList @('-c','core.symlinks=true','submodule','update','--init','--recursive','--force')
        Run-Checked -Title 'Magisk checkout symlink repair' -Exe 'git' -ArgList @('-c','core.symlinks=true','reset','--hard')
        Run-Checked -Title 'Magisk submodule checkout symlink repair' -Exe 'git' -ArgList @('-c','core.symlinks=true','submodule','foreach','--recursive','git reset --hard')
    } finally { Pop-Location }
}

function Patch-MagiskBuildPyOndkTarCompat {
    param([string]$BuildPyPath)
    Need-File $BuildPyPath 'Magisk build.py'
    $raw = [System.IO.File]::ReadAllText($BuildPyPath, [System.Text.Encoding]::UTF8)
    if ($raw.Contains('YAWASAU_PY313_ONDK_TAR_PATCH_V2')) {
        Log '[INFO] Magisk build.py Python 3.13 ONDK tar patch already applied (v2)'
        return
    }

    # Upstream setup_ndk() currently streams ondk-*.tar.xz with tarfile.open(mode="r|xz").
    # On Windows + Python 3.13 this can fail when tar hardlink extraction requires seeking:
    #   tarfile.StreamError: seeking backwards is not allowed
    # v1.4.32 used a narrow nested-with pattern; current upstream has a conditional
    # extractall branch, so rewrite the whole setup_ndk() function instead. The download
    # still comes from official topjohnwu/ondk via official Magisk source; only the local
    # extraction method is changed to a seekable on-disk tar.xz.
    $pattern = '(?ms)^def setup_ndk\(\):\r?\n.*?(?=^def setup_rustup\(\):)'
    $m = [regex]::Match($raw, $pattern)
    if (-not $m.Success) {
        Fail 'Magisk build.py setup_ndk() not found; cannot apply Python 3.13 ONDK tar compatibility patch safely.'
    }

    $newFunc = @'
def setup_ndk():
    # YAWASAU_PY313_ONDK_TAR_PATCH_V2: avoid tarfile streaming r|xz on Windows/Python 3.13.
    url = f"https://github.com/topjohnwu/ondk/releases/download/{ondk_version}/ondk-{ondk_version}-{os_name}.tar.xz"
    ndk_archive = url.split("/")[-1]
    ondk_path = paths().ndk.parent / f"ondk-{ondk_version}"
    tmp_archive = paths().ndk.parent / ndk_archive
    header(f"* Downloading and extracting {ndk_archive}")
    rm_rf(ondk_path)
    rm(tmp_archive)
    try:
        with urllib.request.urlopen(url) as response:
            with open(tmp_archive, "wb") as out:
                shutil.copyfileobj(response, out)
        with tarfile.open(tmp_archive, mode="r:xz") as tar:
            if hasattr(tarfile, "data_filter"):
                tar.extractall(paths().ndk.parent, filter="tar")
            else:
                tar.extractall(paths().ndk.parent)
    finally:
        rm(tmp_archive)

    rm_rf(paths().ndk)
    mv(ondk_path, paths().ndk)

'@

    $raw = $raw.Substring(0, $m.Index) + $newFunc + $raw.Substring($m.Index + $m.Length)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($BuildPyPath, $raw, $encoding)
    Log '[INFO] patched Magisk build.py setup_ndk() for Python 3.13 seekable ONDK tar extraction (v2)'
}

function To-MsysPath([string]$Path) {
    $full = [System.IO.Path]::GetFullPath($Path)
    $drive = $full.Substring(0,1).ToLowerInvariant()
    $rest = $full.Substring(2).Replace('\','/')
    return "/$drive$rest"
}
function Copy-If-Exists([string]$Source, [string]$Dest) {
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Dest) | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Dest -Force
        return $true
    }
    return $false
}

function Flatten-NestedNativeOutIfNeeded {
    param([string]$NativeOutPath)
    $nested = Join-Path $NativeOutPath 'native_out'
    if (-not (Test-Path -LiteralPath $nested -PathType Container)) { return }
    $pairs = @(
        @('bin\bindfs','bindfs'),
        @('lib\libfuse3.so','libfuse3.so'),
        @('bin\magiskpolicy','magiskpolicy'),
        @('SHA256SUMS.txt','SHA256SUMS.txt')
    )
    foreach ($pair in $pairs) {
        $rel = [string]$pair[0]
        $label = [string]$pair[1]
        $src = Join-Path $nested $rel
        $dst = Join-Path $NativeOutPath $rel
        if ((Test-Path -LiteralPath $src -PathType Leaf) -and (-not (Test-Path -LiteralPath $dst -PathType Leaf))) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Log "[INFO] flattened nested native_out artifact for -SkipBindfs: $label"
        }
    }
}
function Test-SkipBindfsArtifacts([string]$NativeOutPath) {
    Flatten-NestedNativeOutIfNeeded -NativeOutPath $NativeOutPath
    $bindfsExisting = Join-Path $NativeOutPath 'bin\bindfs'
    if (Test-Path -LiteralPath $bindfsExisting -PathType Leaf) {
        Log '[INFO] SkipBindfs enabled; preserving existing static-fuse bindfs artifact.'
        return $true
    }
    Log '[WARN] SkipBindfs was requested but native_out bindfs is missing; rebuilding static-fuse bindfs automatically.'
    Log ("[WARN] missing check: {0} exists=False" -f $bindfsExisting)
    return $false
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if ($parent -and (-not (Test-Path -LiteralPath $parent -PathType Container))) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}
function Bash-SingleQuote([string]$Text) {
    if ($Text.Contains("'")) { Fail "MSYS2 script path contains a single quote, unsupported: $Text" }
    return "'" + $Text + "'"
}
function Invoke-Msys2ScriptChecked {
    param([string]$Title, [string]$BashPath, [string]$ScriptPath, [string]$ScriptText)
    Write-Utf8NoBom -Path $ScriptPath -Text $ScriptText
    $msysScript = To-MsysPath $ScriptPath
    Run-Checked -Title $Title -Exe $BashPath -ArgList @('-lc', ('bash ' + (Bash-SingleQuote $msysScript)))
}



function Find-Msys2Bash() {
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
            return $bashPath
        }
    }

    $pathBash = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($pathBash) {
        foreach ($cmd in @($pathBash)) {
            $bashPath = $cmd.Source
            if ($bashPath -match '\\usr\\bin\\bash\.exe$') {
                $rootGuess = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bashPath))
                $pacmanPath = Join-Path $rootGuess 'usr\bin\pacman.exe'
                if (Test-Path -LiteralPath $pacmanPath -PathType Leaf) { return $bashPath }
            }
        }
    }
    return $null
}
function Resolve-Msys2Bash() {
    $found = Find-Msys2Bash
    if ($found) { return $found }

    if ($AutoInstallMsys2) {
        $helper = Join-Path $ScriptDir 'check_msys2_native_deps_windows.ps1'
        Need-File $helper 'check_msys2_native_deps_windows.ps1'
        Log '[INFO] MSYS2 not found; AutoInstallMsys2 enabled, invoking helper with winget bootstrap.'
        Run-Checked -Title 'install MSYS2 + native deps' -Exe 'powershell' -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$helper,'-Msys2Root',$Msys2Root,'-AutoInstallWinget','-InstallPackages')
        $found = Find-Msys2Bash
        if ($found) { return $found }
        Fail 'MSYS2 bootstrap completed but bash.exe is still not discoverable. Rerun with -Msys2Root <actual-msys2-root>.'
    }

    Fail @"
MSYS2 bash.exe not found.
Checked root: $Msys2Root and common locations: C:\msys64, C:\msys2, D:\msys64, D:\msys2, LocalAppData\Programs\MSYS2, PATH.
This build needs MSYS2 because bindfs/libfuse use Meson/Autotools shell build steps.
Fix one of these ways:
  1) Install MSYS2 to C:\msys64, then run:
     C:\msys64\usr\bin\bash.exe -lc "pacman -S --needed --noconfirm meson ninja pkgconf autoconf automake libtool make python git file"
  2) If MSYS2 is installed elsewhere, rerun with:
     -Msys2Root D:\path\to\msys64
  3) Let the helper try winget install + package setup:
     powershell -ExecutionPolicy Bypass -File .\source\build\check_msys2_native_deps_windows.ps1 -Msys2Root C:\msys64 -AutoInstallWinget -InstallPackages
  4) Or let this build script call the helper:
     powershell -ExecutionPolicy Bypass -File .\source\build\build_yawasau_native_windows.ps1 -AutoInstallMsys2
"@
}
function Check-Msys2BuildTools([string]$BashPath) {
    $checkScript = Join-Path $env:TEMP ("yaw_msys2_tool_check_{0}.sh" -f ([System.Guid]::NewGuid().ToString('N')))
    $script = @'
set -eu
missing=""
for x in meson ninja pkg-config autoreconf automake aclocal libtoolize make python git file; do
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
    $output = & $BashPath -lc $cmd 2>&1
    $rc = $LASTEXITCODE
    foreach ($line in $output) { Log ($line.ToString()) }
    try { Remove-Item -LiteralPath $checkScript -Force -ErrorAction SilentlyContinue } catch { }
    if ($rc -ne 0) {
        $missing = (($output | ForEach-Object { $_.ToString() }) -join ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($missing)) { $missing = 'unknown' }
        Fail @"
MSYS2 build tools missing or check failed: $missing
Install packages with:
  $BashPath -lc "pacman -S --needed --noconfirm meson ninja pkgconf autoconf automake libtool make python git file"
Or run helper:
  powershell -ExecutionPolicy Bypass -File .\source\build\check_msys2_native_deps_windows.ps1 -Msys2Root $Msys2Root -InstallPackages
"@
    }
}

function Resolve-ThirdPartyRoot() {
    if (-not [string]::IsNullOrWhiteSpace($ThirdPartyRoot)) { return [System.IO.Path]::GetFullPath($ThirdPartyRoot) }
    return (Join-Path $RootDir 'third_party')
}
function Download-CheckedSource {
    param([string]$Name, [string]$Url, [string]$ArchivePath)
    if (Test-Path -LiteralPath $ArchivePath -PathType Leaf) {
        Log "[INFO] using existing $Name archive: $ArchivePath"
        return
    }
    $parent = Split-Path -Parent $ArchivePath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Log "[INFO] downloading $Name source: $Url"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $ArchivePath
    } catch {
        Fail "download $Name source failed. Put the source manually, or retry with -NoFetchSources disabled. URL=$Url error=$($_.Exception.Message)"
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash.ToLowerInvariant()
    Log "[INFO] $Name archive sha256=$hash"
}
function Extract-SourceArchive {
    param([string]$Name, [string]$ArchivePath, [string]$DestParent, [string]$ExpectedDir)
    if (Test-Path -LiteralPath $ExpectedDir -PathType Container) {
        Log "[INFO] $Name source exists: $ExpectedDir"
        return
    }
    $tar = Get-Command tar -ErrorAction SilentlyContinue
    if (-not $tar) { Fail "Windows tar not found. Extract $ArchivePath into $DestParent manually." }
    New-Item -ItemType Directory -Force -Path $DestParent | Out-Null
    Log "[INFO] extracting $Name source to $DestParent"
    $output = & $tar.Source -xzf $ArchivePath -C $DestParent 2>&1
    $rc = $LASTEXITCODE
    foreach ($line in $output) { Log ($line.ToString()) }
    if ($rc -ne 0) { Fail "extract $Name source failed rc=$rc archive=$ArchivePath" }
    if (-not (Test-Path -LiteralPath $ExpectedDir -PathType Container)) {
        Fail "$Name extraction finished but expected directory is missing: $ExpectedDir"
    }
}
function Ensure-NativeSourceTree {
    param([string]$Name, [string]$Path, [string]$Url)
    if (Test-Path -LiteralPath $Path -PathType Container) { return }
    if ($NoFetchSources) {
        Fail "$Name source not found: $Path. Download/extract it manually or run again without -NoFetchSources."
    }
    $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    $leaf = Split-Path -Leaf ([System.IO.Path]::GetFullPath($Path))
    $archive = Join-Path $parent ($leaf + '.tar.gz')
    Download-CheckedSource -Name $Name -Url $Url -ArchivePath $archive
    Extract-SourceArchive -Name $Name -ArchivePath $archive -DestParent $parent -ExpectedDir ([System.IO.Path]::GetFullPath($Path))
}
function Write-SourceHashes {
    param([string]$ThirdRoot)
    $hashFile = Join-Path $ThirdRoot 'SHA256SUMS_DOWNLOADED_SOURCES.txt'
    if (-not (Test-Path -LiteralPath $ThirdRoot -PathType Container)) { return }
    Get-ChildItem -LiteralPath $ThirdRoot -Filter '*.tar.gz' -File -ErrorAction SilentlyContinue | ForEach-Object {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        "$hash  $($_.Name)"
    } | Sort-Object | Set-Content -LiteralPath $hashFile -Encoding ASCII
    if (Test-Path -LiteralPath $hashFile -PathType Leaf) { Log "[INFO] source archive hashes: $hashFile" }
}


$ndk = Resolve-NdkRoot
$sdkRootForBuild = Resolve-SdkRootFromNdk $ndk
$toolchain = Join-Path $ndk 'toolchains\llvm\prebuilt\windows-x86_64'
$clang = Join-Path $toolchain "bin\aarch64-linux-android$Api-clang.cmd"
$readelf = Join-Path $toolchain 'bin\llvm-readelf.exe'
$strip = Join-Path $toolchain 'bin\llvm-strip.exe'
Need-File $clang "NDK clang API $Api"
Need-File $readelf 'llvm-readelf'
Need-File $strip 'llvm-strip'

$verifyScript = Join-Path $ScriptDir 'verify_elf_yaw_native.ps1'
Need-File $verifyScript 'verify_elf_yaw_native.ps1'

$outPath = [System.IO.Path]::GetFullPath((Join-Path $RootDir $OutDir))
$workPath = [System.IO.Path]::GetFullPath((Join-Path $RootDir $WorkDir))
if (-not $KeepWork) {
    if (Test-Path -LiteralPath $workPath) { Remove-Item -LiteralPath $workPath -Recurse -Force }
}
# v1.4.37: -SkipBindfs means the caller intentionally reuses an existing
# native_out copied from a previous successful bindfs/libfuse build. Do not
# delete it here; v1.4.36 wiped it and the final pack step failed after
# successfully building official-source magiskpolicy.
if (-not $SkipBindfs) {
    if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path $outPath | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $outPath 'bin') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $outPath 'lib') | Out-Null
New-Item -ItemType Directory -Force -Path $workPath | Out-Null

$alignHex = ('0x{0:x}' -f $PageSize)
Log "YAWAsau native build"
Log "NDK=$ndk"
Log "SDK=$sdkRootForBuild"
Log "API=$Api"
Log "PageSize=$PageSize"
Log "OutDir=$outPath"

if ($SkipBindfs) {
    if (-not (Test-SkipBindfsArtifacts -NativeOutPath $outPath)) { $SkipBindfs = $false }
}

if (-not $SkipBindfs) {
    $tpRoot = Resolve-ThirdPartyRoot
    if ([string]::IsNullOrWhiteSpace($LibfuseSrc)) { $LibfuseSrc = Join-Path $tpRoot 'libfuse-fuse-3.18.2' }
    if ([string]::IsNullOrWhiteSpace($BindfsSrc)) { $BindfsSrc = Join-Path $tpRoot 'bindfs-1.18.4' }
    $LibfuseSrc = [System.IO.Path]::GetFullPath($LibfuseSrc)
    $BindfsSrc = [System.IO.Path]::GetFullPath($BindfsSrc)
    Ensure-NativeSourceTree -Name 'libfuse' -Path $LibfuseSrc -Url 'https://github.com/libfuse/libfuse/archive/refs/tags/fuse-3.18.2.tar.gz'
    Ensure-NativeSourceTree -Name 'bindfs' -Path $BindfsSrc -Url 'https://bindfs.org/downloads/bindfs-1.18.4.tar.gz'
    Need-Dir $LibfuseSrc 'libfuse source'
    Need-Dir $BindfsSrc 'bindfs source'
    Write-SourceHashes -ThirdRoot (Split-Path -Parent $LibfuseSrc)

    $bash = Resolve-Msys2Bash
    Log "[INFO] MSYS2 bash=$bash"
    Check-Msys2BuildTools $bash

    $envBlock = @"
set -euo pipefail
export ANDROID_NDK_HOME='$(To-MsysPath $ndk)'
export API='$Api'
export TOOLCHAIN="`$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/windows-x86_64"
export TARGET=aarch64-linux-android
export CC="`$TOOLCHAIN/bin/aarch64-linux-android${Api}-clang.cmd"
export CXX="`$TOOLCHAIN/bin/aarch64-linux-android${Api}-clang++.cmd"
export AR="`$TOOLCHAIN/bin/llvm-ar.exe"
export RANLIB="`$TOOLCHAIN/bin/llvm-ranlib.exe"
export STRIP="`$TOOLCHAIN/bin/llvm-strip.exe"
export NM="`$TOOLCHAIN/bin/llvm-nm.exe"
export OBJDUMP="`$TOOLCHAIN/bin/llvm-objdump.exe"
export READELF="`$TOOLCHAIN/bin/llvm-readelf.exe"
export LD="`$TOOLCHAIN/bin/ld.lld.exe"
# Force Autotools/libtool to use Android NDK LLVM binutils. Without this,
# MSYS2/Windows may fall through to dumpbin/link.exe probing and appear hung.
export lt_cv_path_NM="`$NM"
export ac_cv_path_NM="`$NM"
export ac_cv_prog_NM="`$NM"
export lt_cv_nm_interface="BSD nm"
export ac_cv_prog_ac_ct_DUMPBIN=no
export ac_cv_path_DUMPBIN=no
export ac_cv_prog_DUMPBIN=no
export DUMPBIN=false
# v1.4.19: keep libtool away from MSYS2/Windows PE helpers during Android
# cross configure. If dlltool/windres/windmc are discovered from /usr/bin,
# configure can stall or choose the wrong toolchain branch.
export DLLTOOL=/usr/bin/false
export ac_cv_prog_DLLTOOL=/usr/bin/false
export ac_cv_prog_ac_ct_DLLTOOL=/usr/bin/false
export ac_cv_path_DLLTOOL=/usr/bin/false
export WINDRES=/usr/bin/false
export ac_cv_prog_WINDRES=/usr/bin/false
export ac_cv_prog_ac_ct_WINDRES=/usr/bin/false
export WINDMC=/usr/bin/false
export ac_cv_prog_WINDMC=/usr/bin/false
export ac_cv_prog_ac_ct_WINDMC=/usr/bin/false
# Force the rest of Autotools/libtool host-tool probes to deterministic tools.
# v1.4.12 fixed link.exe/dumpbin fallback, but Windows/MSYS2 can still sit in
# file/objdump/deplibs discovery during Android cross configure.
export FILE=/usr/bin/file
export MAGIC_CMD=/usr/bin/file
export lt_cv_path_MAGIC_CMD=/usr/bin/file
export ac_cv_path_FILE=/usr/bin/file
export ac_cv_prog_FILE=/usr/bin/file
export ac_cv_prog_OBJDUMP="`$OBJDUMP"
export ac_cv_path_OBJDUMP="`$OBJDUMP"
export lt_cv_path_OBJDUMP="`$OBJDUMP"
export ac_cv_prog_AR="`$AR"
export ac_cv_prog_RANLIB="`$RANLIB"
export ac_cv_prog_STRIP="`$STRIP"
export lt_cv_deplibs_check_method=pass_all
export lt_cv_sys_max_cmd_len=8192
export lt_cv_objdir=.libs
export ac_cv_func_malloc_0_nonnull=yes
export ac_cv_func_realloc_0_nonnull=yes
export CONFIG_SITE=/dev/null
export PKG_CONFIG_ALLOW_CROSS=1
export OUT='$(To-MsysPath $outPath)'
export WORK='$(To-MsysPath $workPath)'
export LIBFUSE_SRC='$(To-MsysPath $LibfuseSrc)'
export BINDFS_SRC='$(To-MsysPath $BindfsSrc)'
mkdir -p "`$OUT/bin" "`$OUT/lib" "`$WORK" "`$WORK/fakebin"
# v1.4.15: avoid MSYS2/Windows file(1) magic probing hangs during libtool
# Android cross configure. Libtool only needs a deterministic answer for
# dependency checks, and deplibs are forced to pass_all below.
cat > "`$WORK/fakebin/file" <<'FAKEFILE'
#!/usr/bin/env sh
echo "`$*: ELF 64-bit LSB shared object, ARM aarch64, dynamically linked"
exit 0
FAKEFILE
chmod +x "`$WORK/fakebin/file"
cp -f "`$WORK/fakebin/file" "`$WORK/fakebin/aarch64-linux-android-file"
# Force Windows/PE helper probes to fail fast and deterministically. Android
# targets do not need dlltool/windres/windmc; using MSYS2 host versions can make
# libtool wander into PE/COFF discovery and hang at configure time.
cat > "`$WORK/fakebin/dlltool" <<'FAKEPE'
#!/usr/bin/env sh
exit 1
FAKEPE
chmod +x "`$WORK/fakebin/dlltool"
cp -f "`$WORK/fakebin/dlltool" "`$WORK/fakebin/aarch64-linux-android-dlltool"
cp -f "`$WORK/fakebin/dlltool" "`$WORK/fakebin/windres"
cp -f "`$WORK/fakebin/dlltool" "`$WORK/fakebin/aarch64-linux-android-windres"
cp -f "`$WORK/fakebin/dlltool" "`$WORK/fakebin/windmc"
cp -f "`$WORK/fakebin/dlltool" "`$WORK/fakebin/aarch64-linux-android-windmc"

# Deterministic pkg-config for bindfs. Autotools may discover MSYS2 host
# /usr/bin/pkg-config and then stall or resolve host .pc state. Android bindfs
# only needs the just-built libfuse metadata from `$OUT, so provide a tiny
# wrapper and make both prefixed/unprefixed probes resolve to it.
cat > "`$WORK/fakebin/pkg-config" <<'FAKEPKG'
#!/usr/bin/env sh
# v1.4.19: deterministic wrapper for bindfs only. Accept Autoconf's quoted
# module expressions such as "fuse3 >= 3.4.0" and pkg-config self checks,
# but fail closed for unrelated packages so liburing/numa/udev never become
# false positives.
out="`${YAW_NATIVE_OUT:-}"
if [ -z "`$out" ]; then
  out="__YAW_NATIVE_OUT_UNSET__"
fi
args=" `$* "
for arg in "`$@"; do
  case "`$arg" in
    --version) echo "0.29.2"; exit 0 ;;
    --atleast-pkgconfig-version|--atleast-pkgconfig-version=*) exit 0 ;;
    --help|--print-variables) exit 0 ;;
  esac
done
case "`$args" in
  *liburing*|*numa*|*udev*|*fuse-t*) exit 1 ;;
esac
case "`$args" in
  *fuse3*|*libfuse3*|*fuse*|*libfuse*) ;;
  *) exit 1 ;;
esac
for arg in "`$@"; do
  case "`$arg" in
    --modversion) echo "3.18.2"; exit 0 ;;
    --variable=prefix) echo "`$out"; exit 0 ;;
    --variable=libdir) echo "`$out/lib"; exit 0 ;;
    --variable=includedir) echo "`$out/include"; exit 0 ;;
    --variable=pc_path) echo "`$out/lib/pkgconfig"; exit 0 ;;
    --exists|--atleast-version=*|--exact-version=*|--max-version=*) exit 0 ;;
  esac
done
need_cflags=no
need_libs=no
for arg in "`$@"; do
  case "`$arg" in
    --cflags|--cflags-only-I|--cflags-only-other) need_cflags=yes ;;
    --libs|--libs-only-l|--libs-only-L|--libs-only-other) need_libs=yes ;;
    --print-errors|--silence-errors|--errors-to-stdout|--short-errors) ;;
  esac
done
if [ "`$need_cflags" = yes ]; then
  case "`$args" in
    *" --cflags-only-other "*) printf '%s\n' "" ;;
    *) printf '%s\n' "-I`$out/include/fuse3" ;;
  esac
fi
if [ "`$need_libs" = yes ]; then
  case "`$args" in
    *" --libs-only-l "*) printf '%s\n' "-lfuse3 -ldl" ;;
    *" --libs-only-L "*) printf '%s\n' "-L`$out/lib" ;;
    *" --libs-only-other "*) printf '%s\n' "" ;;
    *) printf '%s\n' "-L`$out/lib -lfuse3 -ldl" ;;
  esac
fi
exit 0
FAKEPKG
chmod +x "`$WORK/fakebin/pkg-config"
cp -f "`$WORK/fakebin/pkg-config" "`$WORK/fakebin/aarch64-linux-android-pkg-config"
export PATH="`$WORK/fakebin:`$PATH"
export FILE="`$WORK/fakebin/file"
export MAGIC_CMD="`$WORK/fakebin/file"
export ac_cv_path_MAGIC_CMD="`$WORK/fakebin/aarch64-linux-android-file"
export ac_cv_path_ac_pt_MAGIC_CMD="`$WORK/fakebin/file"
export ac_cv_prog_MAGIC_CMD="`$WORK/fakebin/file"
export ac_cv_path_FILE="`$WORK/fakebin/aarch64-linux-android-file"
export ac_cv_path_ac_pt_FILE="`$WORK/fakebin/file"
export ac_cv_prog_FILE="`$WORK/fakebin/file"
export ac_cv_prog_ac_ct_FILE="`$WORK/fakebin/file"
export DLLTOOL="`$WORK/fakebin/dlltool"
export ac_cv_prog_DLLTOOL="`$WORK/fakebin/aarch64-linux-android-dlltool"
export ac_cv_prog_ac_ct_DLLTOOL="`$WORK/fakebin/dlltool"
export ac_cv_path_DLLTOOL="`$WORK/fakebin/aarch64-linux-android-dlltool"
export WINDRES="`$WORK/fakebin/windres"
export ac_cv_prog_WINDRES="`$WORK/fakebin/aarch64-linux-android-windres"
export ac_cv_prog_ac_ct_WINDRES="`$WORK/fakebin/windres"
export WINDMC="`$WORK/fakebin/windmc"
export ac_cv_prog_WINDMC="`$WORK/fakebin/aarch64-linux-android-windmc"
export ac_cv_prog_ac_ct_WINDMC="`$WORK/fakebin/windmc"
"@

    $crossFile = Join-Path $workPath 'android-aarch64-ndk28-api28.ini'
    $crossText = @"
[binaries]
c = 'aarch64-linux-android$Api-clang.cmd'
cpp = 'aarch64-linux-android$Api-clang++.cmd'
ar = 'llvm-ar.exe'
strip = 'llvm-strip.exe'
pkg-config = '/usr/bin/pkg-config'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['-O2', '-fPIC', '-D_FILE_OFFSET_BITS=64']
c_link_args = ['-Wl,-z,max-page-size=$PageSize', '-Wl,-z,common-page-size=$PageSize']
cpp_args = ['-O2', '-fPIC', '-D_FILE_OFFSET_BITS=64']
cpp_link_args = ['-Wl,-z,max-page-size=$PageSize', '-Wl,-z,common-page-size=$PageSize']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8-a'
endian = 'little'
"@
    Write-Utf8NoBom -Path $crossFile -Text $crossText

    $buildSh = Join-Path $workPath 'build_bindfs_libfuse.sh'
    # Keep linker literal $ORIGIN out of PowerShell interpolation. The generated
    # shell script must receive "\$ORIGIN" so sh does not expand it before ld.
    $rpathOrigin = '$ORIGIN'
    $buildText = @"
$envBlock
export PATH="`$WORK/fakebin:`$TOOLCHAIN/bin:/usr/bin:/mingw64/bin:`$PATH"
export YAW_NATIVE_OUT="`$OUT"
export PKG_CONFIG="`$WORK/fakebin/pkg-config"
export PKG_CONFIG_PATH="`$OUT/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="`$OUT/lib/pkgconfig"
export FUSE_CFLAGS="-I`$OUT/include/fuse3"
export FUSE_LIBS="-L`$OUT/lib -lfuse3 -ldl"
export fuse_CFLAGS="`$FUSE_CFLAGS"
export fuse_LIBS="`$FUSE_LIBS"

# Android bionic compatibility patches for libfuse upstream source.
# Keep source tarball hashes unchanged; patch only the extracted local build tree.
python - <<'PY'
import os
import re
from pathlib import Path

root = Path(os.environ['LIBFUSE_SRC'])
patched = []

def write_if_changed(path: Path, text: str, label: str):
    old = path.read_text(encoding='utf-8')
    if text != old:
        path.write_text(text, encoding='utf-8')
        patched.append(label)

# 1) Android bionic has no independent librt; realtime/clock symbols are in libc.
p = root / 'lib' / 'meson.build'
s = p.read_text(encoding='utf-8')
s2 = re.sub(r"cc\.find_library\(\s*['\"]rt['\"](?:\s*,[^)]*)?\)", "declare_dependency()", s)
# 2) Android is Linux-kernel based. Make libfuse Meson choose Linux mount code
# instead of falling through to BSD mount helpers when upstream only checks 'linux'.
s2 = s2.replace("host_machine.system() == 'linux'", "host_machine.system() in ['linux', 'android']")
s2 = s2.replace('host_machine.system() == \"linux\"', 'host_machine.system() in [\"linux\", \"android\"]')
s2 = s2.replace("host_machine.system() != 'linux'", "host_machine.system() not in ['linux', 'android']")
s2 = s2.replace('host_machine.system() != \"linux\"', 'host_machine.system() not in [\"linux\", \"android\"]')
write_if_changed(p, s2, 'meson android linux/librt')

shim = r'''

/* YAWAsau Android bionic compat: bionic does not expose POSIX pthread cancellation. */
#if defined(__ANDROID__)
#ifndef PTHREAD_CANCEL_ENABLE
#define PTHREAD_CANCEL_ENABLE 0
#endif
#ifndef PTHREAD_CANCEL_DISABLE
#define PTHREAD_CANCEL_DISABLE 0
#endif
#ifndef YAW_ANDROID_PTHREAD_CANCEL_SHIM
#define YAW_ANDROID_PTHREAD_CANCEL_SHIM 1
static inline int yaw_android_pthread_cancel(pthread_t thread) { (void)thread; return 0; }
static inline int yaw_android_pthread_setcancelstate(int state, int *oldstate) { if (oldstate) *oldstate = PTHREAD_CANCEL_DISABLE; (void)state; return 0; }
#define pthread_cancel yaw_android_pthread_cancel
#define pthread_setcancelstate yaw_android_pthread_setcancelstate
#endif
#endif
'''

def inject_after_pthread(path: Path, label: str):
    txt = path.read_text(encoding='utf-8')
    if 'YAW_ANDROID_PTHREAD_CANCEL_SHIM' in txt:
        return
    marker = '#include <pthread.h>'
    if marker in txt:
        txt = txt.replace(marker, marker + shim, 1)
    else:
        # Fallback: put it after the last leading #include so pthread_t is still normally available.
        lines = txt.splitlines(True)
        pos = 0
        for i, line in enumerate(lines):
            if line.startswith('#include'):
                pos = i + 1
        lines.insert(pos, '#include <pthread.h>\n' + shim)
        txt = ''.join(lines)
    write_if_changed(path, txt, label)

for rel in ('lib/fuse.c', 'lib/fuse_loop_mt.c'):
    fp = root / rel
    if fp.exists():
        inject_after_pthread(fp, rel + ' pthread cancel shim')

# If upstream still builds the BSD mount helper for an Android cross build, make it compile.
bsd = root / 'lib' / 'mount_bsd.c'
if bsd.exists():
    txt = bsd.read_text(encoding='utf-8')
    if 'YAW_ANDROID_MOUNT_BSD_SHIM' not in txt:
        bsd_shim = r'''

/* YAWAsau Android bionic compat: BSD unmount(2) is umount(2) on Android. */
#if defined(__ANDROID__)
#ifndef MNT_FORCE
#define MNT_FORCE 0
#endif
#ifndef YAW_ANDROID_MOUNT_BSD_SHIM
#define YAW_ANDROID_MOUNT_BSD_SHIM 1
#define unmount(target, flags) umount(target)
#endif
#endif
'''
        marker = '#include <sys/mount.h>'
        if marker in txt:
            txt = txt.replace(marker, marker + bsd_shim, 1)
        else:
            txt = '#include <sys/mount.h>\n' + bsd_shim + txt
        write_if_changed(bsd, txt, 'mount_bsd android umount shim')

if patched:
    print('[INFO] patched libfuse Android bionic compatibility: ' + ', '.join(patched))
else:
    print('[INFO] libfuse Android bionic compatibility patches not needed')
PY

cd "`$LIBFUSE_SRC"
rm -rf build-android
meson setup build-android --cross-file '$(To-MsysPath $crossFile)' --prefix "`$OUT" --libdir lib --default-library=static -Dexamples=false -Dtests=false
ninja -C build-android

# Do not run "ninja install" on Windows/MSYS2: upstream libfuse install rules
# try to chown fusermount3 to root:root, which fails on Windows. YAWAsau only
# needs libfuse3.a + headers + pkg-config metadata for static-fuse bindfs.
mkdir -p "`$OUT/lib" "`$OUT/include" "`$OUT/lib/pkgconfig"
_libfuse_built="`$(find build-android/lib -maxdepth 1 -type f -name 'libfuse3.a' | sort | head -n 1)"
if [ -z "`$_libfuse_built" ]; then
  echo "[ERROR] libfuse3.a static build artifact not found under build-android/lib" >&2
  find build-android -maxdepth 3 -type f -name 'libfuse3.*' >&2 || true
  exit 21
fi
cp -f "`$_libfuse_built" "`$OUT/lib/libfuse3.a"
rm -rf "`$OUT/include/fuse3"
mkdir -p "`$OUT/include/fuse3"
# libfuse upstream source keeps headers as include/*.h; meson install would
# relocate them to include/fuse3, but we intentionally skip ninja install on
# Windows/MSYS2 to avoid chown root:root. Collect headers manually.
if [ -d include/fuse3 ]; then
  cp -a include/fuse3/. "`$OUT/include/fuse3/"
elif ls include/*.h >/dev/null 2>&1; then
  cp -f include/*.h "`$OUT/include/fuse3/"
else
  echo "[ERROR] libfuse headers not found under include/" >&2
  find include -maxdepth 2 -type f >&2 || true
  exit 23
fi
# libfuse headers include generated private config headers. Meson creates
# these in build-android, not in upstream include/*.h. Since we skip
# ninja install on MSYS2, collect them explicitly into the same include/fuse3
# directory, otherwise direct bindfs clang fails at fuse_common.h including
# libfuse_config.h.
for _cfg_hdr in libfuse_config.h fuse_config.h; do
  _cfg_path="`$(find build-android -type f -name "`$_cfg_hdr" | sort | head -n 1)"
  if [ -n "`$_cfg_path" ]; then
    cp -f "`$_cfg_path" "`$OUT/include/fuse3/`$_cfg_hdr"
    echo "[INFO] collected generated libfuse header: `$_cfg_hdr <- `$_cfg_path"
  elif [ "`$_cfg_hdr" = "libfuse_config.h" ]; then
    echo "[ERROR] required generated libfuse header not found: `$_cfg_hdr" >&2
    find build-android -type f \( -name 'libfuse_config.h' -o -name 'fuse_config.h' \) >&2 || true
    exit 24
  else
    echo "[WARN] optional generated libfuse header not found: `$_cfg_hdr" >&2
  fi
done
cat > "`$OUT/lib/pkgconfig/fuse3.pc" <<PC
prefix=`$OUT
exec_prefix=`$OUT
libdir=`$OUT/lib
includedir=`$OUT/include

Name: fuse3
Description: Filesystem in Userspace
Version: 3.18.2
Libs: -L`$OUT/lib -lfuse3 -ldl
Cflags: -I`$OUT/include/fuse3
PC
cat > "`$OUT/lib/pkgconfig/fuse.pc" <<PC
prefix=`$OUT
exec_prefix=`$OUT
libdir=`$OUT/lib
includedir=`$OUT/include

Name: fuse
Description: Filesystem in Userspace compatibility alias for Android bindfs build
Version: 3.18.2
Libs: -L`$OUT/lib -lfuse3 -ldl
Cflags: -I`$OUT/include/fuse3
PC

export PKG_CONFIG_PATH="`$OUT/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="`$OUT/lib/pkgconfig"
cd "`$BINDFS_SRC"
if [ ! -x ./configure ]; then
  if command -v autoreconf >/dev/null 2>&1; then autoreconf -fi; fi
fi
make distclean >/dev/null 2>&1 || true

# Autotools/libtool on Windows/MSYS2 may keep probing host-side file magic,
# dumpbin/link.exe, or deplibs even when target LLVM tools are already known.
# v1.4.13 still stopped at "checking for file... file" on the user's MSYS2.
# Feed configure an explicit cache file so Android cross configure is
# deterministic and does not wander into Windows tool discovery.
cat > "`$WORK/bindfs-config.cache" <<CACHE
ac_cv_build='x86_64-pc-msys'
ac_cv_host='aarch64-unknown-linux-android'
ac_cv_prog_CC='`$CC'
ac_cv_prog_CPP='`$CC -E'
ac_cv_prog_NM='`$NM'
ac_cv_path_NM='`$NM'
lt_cv_path_NM='`$NM'
lt_cv_nm_interface='BSD nm'
ac_cv_prog_AR='`$AR'
ac_cv_prog_RANLIB='`$RANLIB'
ac_cv_prog_STRIP='`$STRIP'
ac_cv_prog_OBJDUMP='`$OBJDUMP'
ac_cv_path_OBJDUMP='`$OBJDUMP'
lt_cv_path_OBJDUMP='`$OBJDUMP'
ac_cv_prog_READELF='`$READELF'
ac_cv_prog_LD='`$LD'
lt_cv_prog_gnu_ld='yes'
lt_cv_ld_reload_flag='-r'
ac_cv_prog_DLLTOOL='`$WORK/fakebin/aarch64-linux-android-dlltool'
ac_cv_prog_ac_ct_DLLTOOL='`$WORK/fakebin/dlltool'
ac_cv_path_DLLTOOL='`$WORK/fakebin/aarch64-linux-android-dlltool'
ac_cv_prog_WINDRES='`$WORK/fakebin/aarch64-linux-android-windres'
ac_cv_prog_ac_ct_WINDRES='`$WORK/fakebin/windres'
ac_cv_prog_WINDMC='`$WORK/fakebin/aarch64-linux-android-windmc'
ac_cv_prog_ac_ct_WINDMC='`$WORK/fakebin/windmc'
ac_cv_prog_ac_ct_DUMPBIN='no'
ac_cv_path_DUMPBIN='no'
ac_cv_prog_DUMPBIN='no'
lt_cv_path_MAGIC_CMD='`$WORK/fakebin/file'
lt_cv_file_magic_cmd='`$WORK/fakebin/file'
lt_cv_file_magic_test_file='/usr/bin/bash'
ac_cv_path_MAGIC_CMD='`$WORK/fakebin/aarch64-linux-android-file'
ac_cv_path_ac_pt_MAGIC_CMD='`$WORK/fakebin/file'
ac_cv_prog_MAGIC_CMD='`$WORK/fakebin/file'
ac_cv_path_FILE='`$WORK/fakebin/aarch64-linux-android-file'
ac_cv_path_ac_pt_FILE='`$WORK/fakebin/file'
ac_cv_prog_FILE='`$WORK/fakebin/file'
ac_cv_prog_ac_ct_FILE='`$WORK/fakebin/file'
ac_cv_path_PKG_CONFIG='`$WORK/fakebin/aarch64-linux-android-pkg-config'
ac_cv_path_ac_pt_PKG_CONFIG='`$WORK/fakebin/pkg-config'
ac_cv_prog_PKG_CONFIG='`$WORK/fakebin/pkg-config'
ac_cv_prog_ac_ct_PKG_CONFIG='`$WORK/fakebin/pkg-config'
pkg_cv_FUSE_CFLAGS='-I`$OUT/include/fuse3'
pkg_cv_FUSE_LIBS='-L`$OUT/lib -lfuse3 -ldl'
pkg_cv_fuse_CFLAGS='-I`$OUT/include/fuse3'
pkg_cv_fuse_LIBS='-L`$OUT/lib -lfuse3 -ldl'
pkg_cv_fuse3_CFLAGS='-I`$OUT/include/fuse3'
pkg_cv_fuse3_LIBS='-L`$OUT/lib -lfuse3 -ldl'
pkg_cv_LIBFUSE_CFLAGS='-I`$OUT/include/fuse3'
pkg_cv_LIBFUSE_LIBS='-L`$OUT/lib -lfuse3 -ldl'
pkg_cv_LIBFUSE3_CFLAGS='-I`$OUT/include/fuse3'
pkg_cv_LIBFUSE3_LIBS='-L`$OUT/lib -lfuse3 -ldl'
lt_cv_deplibs_check_method='pass_all'
lt_cv_sys_max_cmd_len='8192'
lt_cv_objdir='.libs'
lt_cv_prog_compiler_pic='-fPIC'
lt_cv_prog_compiler_static='-static'
lt_cv_prog_compiler_c_o='yes'
lt_cv_prog_compiler_can_build_shared='yes'
lt_cv_prog_compiler_pic_works='yes'
lt_cv_prog_compiler_static_works='yes'
lt_cv_archive_cmds_need_lc='no'
lt_cv_shlibpath_overrides_runpath='no'
lt_cv_sys_lib_search_path_spec=''
lt_cv_sys_lib_dlsearch_path_spec='/system/lib64 /vendor/lib64'
am_cv_CC_dependencies_compiler_type='none'
ac_cv_func_malloc_0_nonnull='yes'
ac_cv_func_realloc_0_nonnull='yes'
CACHE

echo "[INFO] bindfs configure cache: `$WORK/bindfs-config.cache"
NM="`$NM" AR="`$AR" RANLIB="`$RANLIB" STRIP="`$STRIP" LD="`$LD" OBJDUMP="`$OBJDUMP" READELF="`$READELF" FILE="`$WORK/fakebin/file" MAGIC_CMD="`$WORK/fakebin/file" DLLTOOL="`$WORK/fakebin/dlltool" WINDRES="`$WORK/fakebin/windres" WINDMC="`$WORK/fakebin/windmc" PKG_CONFIG="`$WORK/fakebin/pkg-config" PKG_CONFIG_PATH="`$OUT/lib/pkgconfig" PKG_CONFIG_LIBDIR="`$OUT/lib/pkgconfig" \
  FUSE_CFLAGS="-I`$OUT/include/fuse3" FUSE_LIBS="-L`$OUT/lib -lfuse3 -ldl" fuse_CFLAGS="-I`$OUT/include/fuse3" fuse_LIBS="-L`$OUT/lib -lfuse3 -ldl" fuse3_CFLAGS="-I`$OUT/include/fuse3" fuse3_LIBS="-L`$OUT/lib -lfuse3 -ldl" LIBFUSE3_CFLAGS="-I`$OUT/include/fuse3" LIBFUSE3_LIBS="-L`$OUT/lib -lfuse3 -ldl" \
  ac_cv_path_MAGIC_CMD="`$WORK/fakebin/aarch64-linux-android-file" ac_cv_path_ac_pt_MAGIC_CMD="`$WORK/fakebin/file" \
  ac_cv_path_FILE="`$WORK/fakebin/aarch64-linux-android-file" ac_cv_path_ac_pt_FILE="`$WORK/fakebin/file" \
  ac_cv_path_PKG_CONFIG="`$WORK/fakebin/aarch64-linux-android-pkg-config" ac_cv_path_ac_pt_PKG_CONFIG="`$WORK/fakebin/pkg-config" ac_cv_prog_PKG_CONFIG="`$WORK/fakebin/pkg-config" ac_cv_prog_ac_ct_PKG_CONFIG="`$WORK/fakebin/pkg-config" \
  pkg_cv_FUSE_CFLAGS="-I`$OUT/include/fuse3" pkg_cv_FUSE_LIBS="-L`$OUT/lib -lfuse3 -ldl" pkg_cv_fuse_CFLAGS="-I`$OUT/include/fuse3" pkg_cv_fuse_LIBS="-L`$OUT/lib -lfuse3 -ldl" pkg_cv_fuse3_CFLAGS="-I`$OUT/include/fuse3" pkg_cv_fuse3_LIBS="-L`$OUT/lib -lfuse3 -ldl" \
  lt_cv_path_NM="`$NM" ac_cv_path_NM="`$NM" ac_cv_prog_NM="`$NM" lt_cv_nm_interface="BSD nm" \
  ac_cv_prog_DLLTOOL="`$WORK/fakebin/aarch64-linux-android-dlltool" ac_cv_prog_ac_ct_DLLTOOL="`$WORK/fakebin/dlltool" ac_cv_path_DLLTOOL="`$WORK/fakebin/aarch64-linux-android-dlltool" \
  ac_cv_prog_WINDRES="`$WORK/fakebin/aarch64-linux-android-windres" ac_cv_prog_ac_ct_WINDRES="`$WORK/fakebin/windres" ac_cv_prog_WINDMC="`$WORK/fakebin/aarch64-linux-android-windmc" ac_cv_prog_ac_ct_WINDMC="`$WORK/fakebin/windmc" \
  ac_cv_prog_ac_ct_DUMPBIN=no ac_cv_path_DUMPBIN=no ac_cv_prog_DUMPBIN=no DUMPBIN=false \
  lt_cv_path_MAGIC_CMD="`$WORK/fakebin/file" lt_cv_file_magic_cmd="`$WORK/fakebin/file" lt_cv_deplibs_check_method=pass_all \
  ./configure --cache-file="`$WORK/bindfs-config.cache" --host=aarch64-linux-android --build=x86_64-pc-msys --with-fuse3 --disable-dependency-tracking --disable-libtool-lock --prefix="`$OUT" --libdir="`$OUT/lib" CC="`$CC" CPPFLAGS="-I`$OUT/include/fuse3 -I`$OUT/include" CFLAGS="-O2 -fPIE -D_FILE_OFFSET_BITS=64" LDFLAGS="-pie -L`$OUT/lib -Wl,-rpath,\${rpathOrigin}/../lib -Wl,-z,max-page-size=$PageSize -Wl,-z,common-page-size=$PageSize"
# Cross-building bindfs for Android should not recurse into upstream tests.
# v1.4.19 reached configure and started compiling, but MSYS2 Autotools make
# could become silent/stuck after spawning nested make processes. v1.4.20
# replaced make with direct clang, but some Windows/MSYS2 setups can hang when
# invoking the NDK target .cmd wrapper for the first source file. v1.4.21 uses
# clang.exe with an explicit --target plus per-step timeout and diagnostics.
# v1.4.22 fixes the Windows PowerShell stderr runner so clang diagnostics are
# not truncated at the first NativeCommandError line. v1.4.23 also collects
# Meson-generated libfuse_config.h/fuse_config.h and lets bindfs config.h own
# FUSE_USE_VERSION, avoiding command-line macro redefinition.
echo "[INFO] direct compiling static-fuse bindfs with NDK clang.exe --target; generated libfuse headers collected; bindfs config.h owns FUSE_USE_VERSION"
export DIRECT_CC="`$TOOLCHAIN/bin/clang.exe"
export DIRECT_TARGET="aarch64-linux-android$Api"
export DIRECT_SYSROOT="`$TOOLCHAIN/sysroot"
if [ ! -f "`$DIRECT_CC" ]; then
  echo "[ERROR] clang.exe not found: `$DIRECT_CC" >&2
  exit 33
fi
_bindfs_timeout="`${YAW_NATIVE_COMPILE_TIMEOUT_SECONDS:-120}"
_yaw_run_native() {
  _label="`$1"; shift
  echo "[RUN] `$_label timeout=`${_bindfs_timeout}s"
  echo "[CMD] `$*"
  if command -v timeout >/dev/null 2>&1; then
    timeout "`${_bindfs_timeout}s" "`$@"
    _rc=`$?
    if [ "`$_rc" -eq 124 ]; then
      echo "[ERROR] timeout while running: `$_label" >&2
      echo "[ERROR] last command: `$*" >&2
      exit 124
    fi
  else
    "`$@"
    _rc=`$?
  fi
  if [ "`$_rc" -ne 0 ]; then
    echo "[ERROR] failed: `$_label rc=`$_rc" >&2
    exit "`$_rc"
  fi
  echo "[DONE] `$_label"
}
cd src
rm -f bindfs bindfs.direct *.o
_bindfs_srcs="bindfs.c debug.c permchain.c userinfo.c arena.c misc.c usermap.c rate_limiter.c"
_bindfs_objs=""
for _src in `$_bindfs_srcs; do
  if [ ! -f "`$_src" ]; then
    echo "[ERROR] bindfs source missing: `$_src" >&2
    ls -la >&2 || true
    exit 31
  fi
  _obj="`${_src%.c}.o"
  echo "[CC] `$_src -> `$_obj"
  _yaw_run_native "CC `$_src"     "`$DIRECT_CC" --target="`$DIRECT_TARGET" --sysroot="`$DIRECT_SYSROOT"     -DHAVE_CONFIG_H -I. -I..     -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_XOPEN_SOURCE=700 -D__BSD_VISIBLE=1 -D_BSD_SOURCE -D_DEFAULT_SOURCE -D_DARWIN_BETTER_REALPATH -D_DARWIN_C_SOURCE     -I"`$OUT/include/fuse3" -I"`$OUT/include"     -std=gnu11 -Wall -Wextra -Wpedantic -fdiagnostics-color=never -fno-common -O2 -fPIE -D_FILE_OFFSET_BITS=64     -c -o "`$_obj" "`$_src"
  _bindfs_objs="`$_bindfs_objs `$_obj"
done

echo "[LD] bindfs"
_yaw_run_native "LD bindfs"   "`$DIRECT_CC" --target="`$DIRECT_TARGET" --sysroot="`$DIRECT_SYSROOT"   -pie -o bindfs `$_bindfs_objs   "`$OUT/lib/libfuse3.a" -ldl   -Wl,-z,max-page-size=$PageSize -Wl,-z,common-page-size=$PageSize
cd ..
# Avoid "make install" too: some Autotools install rules may call owner/group
# preserving install/chown on MSYS2. Copy only the runtime binary we need.
_bindfs_built=""
for _cand in src/bindfs bindfs; do
  if [ -f "`$_cand" ]; then _bindfs_built="`$_cand"; break; fi
done
if [ -z "`$_bindfs_built" ]; then
  echo "[ERROR] bindfs build artifact not found" >&2
  find . -maxdepth 3 -type f -name 'bindfs*' >&2 || true
  exit 22
fi
mkdir -p "`$OUT/bin"
cp -f "`$_bindfs_built" "`$OUT/bin/bindfs"
chmod +x "`$OUT/bin/bindfs" 2>/dev/null || true
"@
    Write-Utf8NoBom -Path $buildSh -Text $buildText

    Run-Checked -Title 'build libfuse3 + bindfs via MSYS2' -Exe $bash -ArgList @('-lc', ('bash ' + (Bash-SingleQuote (To-MsysPath $buildSh))))

    $libfuseStaticOut = Join-Path $outPath 'lib\libfuse3.a'
    $bindfsOut = Join-Path $outPath 'bin\bindfs'
    Need-File $libfuseStaticOut 'libfuse3.a static output'
    Need-File $bindfsOut 'static-fuse bindfs output'
    Run-Checked -Title 'strip bindfs' -Exe $strip -ArgList @('--strip-all', $bindfsOut)
    Run-Checked -Title 'verify static-fuse bindfs' -Exe 'powershell' -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$verifyScript,'-Readelf',$readelf,'-Binary',$bindfsOut,'-Mode','android-exe','-ExpectedLoadAlign',$alignHex,'-ExpectedRelroEndAlign',$alignHex,'-AllowedNeeded','libc.so,libdl.so','-RequireLibc')
}


# v1.4.78: native stable-content confwatch. It keeps inotify, inode-rename
# recovery and content hash debounce inside the native helper, so service.sh no
# longer needs a permanent shell cksum/sleep polling loop.
$confwatchSrc = Join-Path $RootDir 'source\confwatch.c'
$confwatchStart = Join-Path $RootDir 'source\confwatch_start.S'
Need-File $confwatchSrc 'confwatch.c'
Need-File $confwatchStart 'confwatch_start.S'
$confwatchOut = Join-Path $outPath 'bin\confwatch'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $confwatchOut) | Out-Null
$clangExe = Join-Path $toolchain 'bin\clang.exe'
Need-File $clangExe 'NDK clang.exe'
$sysroot = Join-Path $toolchain 'sysroot'
$target = "aarch64-linux-android$Api"
Run-Checked -Title 'build native confwatch stable-content watcher' -Exe $clangExe -ArgList @(
    "--target=$target",
    '-nostdlib','-static',
    '-Wall','-Wextra','-Werror','-O2',
    "-Wl,-z,max-page-size=$PageSize",
    "-Wl,-z,common-page-size=$PageSize",
    '-o',$confwatchOut,$confwatchStart,$confwatchSrc
)
Run-Checked -Title 'strip native confwatch helper' -Exe $strip -ArgList @('--strip-all', $confwatchOut)
Run-Checked -Title 'verify native confwatch helper' -Exe 'powershell' -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$verifyScript,'-Readelf',$readelf,'-Binary',$confwatchOut,'-Mode','static-nolibc','-ExpectedLoadAlign',$alignHex,'-ExpectedRelroEndAlign',$alignHex)

# v1.4.62: always build the native mount.fuse3 helper used by static libfuse.
$helperSrc = Join-Path $RootDir 'source\mount_fuse3_helper.c'
Need-File $helperSrc 'mount_fuse3_helper.c'
$helperOut = Join-Path $outPath 'bin\mount.fuse3'
$helperAlias = Join-Path $outPath 'bin\mount_fusefs'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $helperOut) | Out-Null
$clangExe = Join-Path $toolchain 'bin\clang.exe'
Need-File $clangExe 'NDK clang.exe'
$sysroot = Join-Path $toolchain 'sysroot'
$target = "aarch64-linux-android$Api"
Run-Checked -Title 'build native mount.fuse3 helper' -Exe $clangExe -ArgList @(
    "--target=$target",
    "--sysroot=$sysroot",
    '-std=gnu11','-Wall','-Wextra','-Werror','-O2','-fPIE','-pie',
    "-Wl,-z,max-page-size=$PageSize",
    "-Wl,-z,common-page-size=$PageSize",
    '-o',$helperOut,$helperSrc
)
Run-Checked -Title 'strip native mount.fuse3 helper' -Exe $strip -ArgList @('--strip-all', $helperOut)
Run-Checked -Title 'verify native mount.fuse3 helper' -Exe 'powershell' -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$verifyScript,'-Readelf',$readelf,'-Binary',$helperOut,'-Mode','android-exe','-ExpectedLoadAlign',$alignHex,'-ExpectedRelroEndAlign',$alignHex,'-AllowedNeeded','libc.so,libdl.so','-RequireLibc')
Copy-Item -LiteralPath $helperOut -Destination $helperAlias -Force


# v1.4.74: native Profile transaction helper.  It owns foreground
# kernel-bind / bindfs_shared switching, visible probe retry, and rollback.
$mounttxSrc = Join-Path $RootDir 'source\mounttx.c'
Need-File $mounttxSrc 'mounttx.c'
$mounttxOut = Join-Path $outPath 'bin\mounttx'
Run-Checked -Title 'build native mounttx profile transaction helper' -Exe $clangExe -ArgList @(
    "--target=$target",
    "--sysroot=$sysroot",
    '-std=gnu11','-Wall','-Wextra','-Werror','-O2','-fPIE','-pie',
    "-Wl,-z,max-page-size=$PageSize",
    "-Wl,-z,common-page-size=$PageSize",
    '-o',$mounttxOut,$mounttxSrc
)
Run-Checked -Title 'strip native mounttx helper' -Exe $strip -ArgList @('--strip-all', $mounttxOut)
Run-Checked -Title 'verify native mounttx helper' -Exe 'powershell' -ArgList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$verifyScript,'-Readelf',$readelf,'-Binary',$mounttxOut,'-Mode','android-exe','-ExpectedLoadAlign',$alignHex,'-ExpectedRelroEndAlign',$alignHex,'-AllowedNeeded','libc.so,libdl.so','-RequireLibc')

if ($BuildMagiskPolicy) {
    if ([string]::IsNullOrWhiteSpace($MagiskSrc)) { $MagiskSrc = Join-Path $RootDir 'third_party\Magisk' }
    $magiskBuildPy = Join-Path $MagiskSrc 'build.py'
    if (-not (Test-Path -LiteralPath $magiskBuildPy -PathType Leaf)) {
        if ($NoFetchMagisk) {
            Fail "official Magisk source not found and -NoFetchMagisk was supplied: $MagiskSrc"
        }
        $fetchMagisk = Join-Path $ScriptDir 'fetch_magisk_official_source_windows.ps1'
        Need-File $fetchMagisk 'fetch_magisk_official_source_windows.ps1'
        Log ''
        Log "[INFO] official Magisk source not found; fetching official topjohnwu/Magisk source to: $MagiskSrc"
        $fetchArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fetchMagisk,'-MagiskSrc',$MagiskSrc)
        if (-not [string]::IsNullOrWhiteSpace($MagiskRef)) { $fetchArgs += @('-Ref',$MagiskRef) }
        Run-Checked -Title 'fetch official Magisk source' -Exe 'powershell' -ArgList $fetchArgs
    }
    Need-Dir $MagiskSrc 'official Magisk source'
    Need-File (Join-Path $MagiskSrc 'build.py') 'Magisk build.py'
    if ($MagiskAbi -ne 'arm64-v8a') { Fail 'This YAWAsau module is arm64 only; MagiskAbi must be arm64-v8a.' }
    Ensure-MagiskGitSymlinkCheckout -Repo $MagiskSrc
    Log ''
    Log '[INFO] Building magiskpolicy from official topjohnwu/Magisk source with Magisk build.py.'
    Log '[INFO] Official Magisk build expects git submodules, Android SDK, JDK 17/Android Studio JDK, and its own ONDK toolchain.'
    Log '[INFO] This follows upstream build.py; do not replace it with the archived standalone topjohnwu/magiskpolicy repo or v2 prebuilt.'
    Set-AndroidSdkEnvForChildTools $sdkRootForBuild
    $magiskCfg = Join-Path $workPath 'magiskpolicy.config.prop'
    @("abiList=$MagiskAbi", 'outdir=out') | Set-Content -LiteralPath $magiskCfg -Encoding ASCII
    $pySpec = Resolve-PythonSpec -RequestedPython $Python
    Log ("[INFO] Python command for Magisk build: {0} {1} ({2})" -f $pySpec.Exe, (($pySpec.PrefixArgs) -join ' '), $pySpec.Version)
    if ($SetupMagiskNdk) {
        Patch-MagiskBuildPyOndkTarCompat -BuildPyPath (Join-Path $MagiskSrc 'build.py')
    }
    Push-Location $MagiskSrc
    try {
        if ($SetupMagiskNdk) {
            Run-Checked -Title 'Magisk setup official ONDK' -Exe $pySpec.Exe -ArgList ([string[]]($pySpec.PrefixArgs + @('build.py','ndk')))
        }
        Run-Checked -Title 'Magisk build native magiskpolicy arm64-v8a release' -Exe $pySpec.Exe -ArgList ([string[]]($pySpec.PrefixArgs + @('build.py','-r','-c',$magiskCfg,'native','magiskpolicy')))
    } finally {
        Pop-Location
    }
    $candidates = @(
        (Join-Path $MagiskSrc 'native\out\arm64-v8a\magiskpolicy'),
        (Join-Path $MagiskSrc 'native\out\arm64\magiskpolicy')
    )
    $mp = $null
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c -PathType Leaf) { $mp = $c; break } }
    if (-not $mp) {
        $outRoot = Join-Path $MagiskSrc 'native\out'
        $found = @(Get-ChildItem -LiteralPath $outRoot -Recurse -Filter magiskpolicy -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        if ($found.Count -gt 0) { $mp = $found[0] } else { Fail 'magiskpolicy output not found under native/out/*/magiskpolicy' }
    }
    $dest = Join-Path $outPath 'bin\magiskpolicy'
    Copy-Item -LiteralPath $mp -Destination $dest -Force
    Run-Checked -Title 'strip magiskpolicy' -Exe $strip -ArgList @('--strip-all', $dest)
    # Magisk upstream may change whether magiskpolicy is static or which system libs it needs.
    # Verify parseability and print the ELF header, but do not over-constrain NEEDED here.
    Run-Checked -Title 'readelf magiskpolicy header' -Exe $readelf -ArgList @('-h',$dest)
    $IncludeMagiskPolicy = $true
} else {
    $bundledMp = Join-Path $RootDir 'bin\magiskpolicy'
    $dest = Join-Path $outPath 'bin\magiskpolicy'
    if (Test-Path -LiteralPath $bundledMp -PathType Leaf) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $bundledMp -Destination $dest -Force
        Log '[INFO] magiskpolicy unchanged; reused bundled known-good binary. Use -BuildMagiskPolicy to rebuild official Magisk source.'
        $IncludeMagiskPolicy = $true
    } else {
        Log '[WARN] bundled bin/magiskpolicy missing; final zip may rely on device-provided magiskpolicy for live sepolicy.'
    }
}
function Get-RelativePathCompat {
    param(
        [Parameter(Mandatory=$true)][string]$BasePath,
        [Parameter(Mandatory=$true)][string]$FullPath
    )
    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    $fileFull = [System.IO.Path]::GetFullPath($FullPath)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if (-not $baseFull.EndsWith([string]$sep)) { $baseFull = $baseFull + $sep }
    if ($fileFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fileFull.Substring($baseFull.Length).Replace('\','/')
    }
    # Fallback for unexpected paths. Avoid .NET Core-only System.IO.Path.GetRelativePath
    # so this script remains compatible with Windows PowerShell 5.1.
    return $fileFull.Replace('\','/')
}

$shaFile = Join-Path $outPath 'SHA256SUMS.txt'
Get-ChildItem -LiteralPath $outPath -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | ForEach-Object {
    $rel = Get-RelativePathCompat -BasePath $outPath -FullPath $_.FullName
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
    "$hash  $rel"
} | Sort-Object | Set-Content -LiteralPath $shaFile -Encoding ASCII

Log ''
Log '[OK] native build completed'
Log "Output: $outPath"
Log 'Module runtime paths after packing:'
Log '  /data/adb/modules/dcimswitch/bin/bindfs (static-fuse; no libfuse3.so runtime dependency)'
Log '  /data/adb/modules/dcimswitch/bin/mount.fuse3 (native mount helper)'
Log '  /data/adb/modules/dcimswitch/bin/mount_fusefs (native mount helper alias)'
Log '  /data/adb/modules/dcimswitch/bin/mounttx (native profile transaction helper)'
Log '  optional: /data/adb/modules/dcimswitch/bin/magiskpolicy'
Log 'Legacy manual fallback remains supported under /data/adb/dcimswitch/native/.'

if ($PackModule) {
    $packScript = Join-Path $ScriptDir 'pack_yawasau_module_windows.ps1'
    Need-File $packScript 'module pack script'
    $packArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$packScript,'-ModuleRoot',$RootDir,'-NativeOut',$outPath)
    if (-not [string]::IsNullOrWhiteSpace($ModuleZipOut)) { $packArgs += @('-OutZip',$ModuleZipOut) }
    if ($IncludeMagiskPolicy) { $packArgs += @('-IncludeMagiskPolicy') }
    Write-Host '[WARN] build_yawasau_native_windows.ps1 packs native artifacts only. Dex-only notifications require build_yawasau_full_module_windows.ps1.' -ForegroundColor Yellow
    Run-Checked -Title 'pack complete module with native artifacts' -Exe 'powershell' -ArgList $packArgs
}
