param(
    [int]$Api = 28,
    [string]$NdkVersion = '28.2.13676358',
    [string]$NdkRoot = '',
    [string]$Msys2Root = 'C:\msys64',
    [string]$JavaHome = 'C:\Program Files\Android\Android Studio\jbr',
    [string]$SdkPath = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$Python = 'auto',
    [switch]$SkipNative,
    [switch]$SkipDexBuild,
    [switch]$RebuildMagiskPolicy
)
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$native = Join-Path $ScriptDir 'build_yawasau_native_windows.ps1'
$dex = Join-Path $ScriptDir 'build_yawasau_dex_notify_module_windows.ps1'
if (-not $SkipNative) {
    # v1.4.62: use hashtable splatting for PowerShell scripts.
    # v1.4.66: native step does not package; Dex step packages and requires bin/classes.dex.
    # Array splatting passes '-Api' as a positional string on Windows PowerShell 5.1,
    # causing: Cannot convert value "-Api" to type System.Int32.
    $nativeParams = @{
        Api = $Api
        NdkVersion = $NdkVersion
        Msys2Root = $Msys2Root
        Python = $Python
        NoPackModule = $true
    }
    # v1.4.69: magiskpolicy does not change for notify/shell/C helper edits.
    # Default full builds reuse the bundled known-good bin/magiskpolicy so the
    # one-command build will not repeatedly clone Magisk or download ONDK.
    # Pass -RebuildMagiskPolicy only when intentionally refreshing the official-source binary.
    if (-not $RebuildMagiskPolicy) { $nativeParams['NoBuildMagiskPolicy'] = $true }
    if (-not [string]::IsNullOrWhiteSpace($NdkRoot)) { $nativeParams['NdkRoot'] = $NdkRoot }
    & $native @nativeParams
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if (-not $RebuildMagiskPolicy) {
        $root = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
        $bundledMp = Join-Path $root 'bin\magiskpolicy'
        $nativeMp = Join-Path $root 'native_out\bin\magiskpolicy'
        if (Test-Path -LiteralPath $bundledMp -PathType Leaf) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $nativeMp) | Out-Null
            Copy-Item -LiteralPath $bundledMp -Destination $nativeMp -Force
            Write-Host '[INFO] magiskpolicy unchanged; reused bundled known-good binary. Use -RebuildMagiskPolicy to rebuild official Magisk source.' -ForegroundColor Cyan
        } else {
            throw "bundled bin/magiskpolicy missing: $bundledMp"
        }
    }
}
$dexParams = @{
    JavaHome = $JavaHome
    SdkPath = $SdkPath
}
if ($SkipDexBuild) { $dexParams['SkipDexBuild'] = $true }
& $dex @dexParams
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
