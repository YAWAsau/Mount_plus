param(
    [int]$Api = 28,
    [string]$NdkVersion = '28.2.13676358',
    [string]$NdkRoot = '',
    [ValidateSet(4096,16384)][int]$PageSize = 16384,
    [string]$OutZip = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent (Split-Path -Parent $ScriptDir)
Set-Location $RootDir

function Fail([string]$m) { throw $m }
function NeedFile([string]$p, [string]$label) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Fail "$label missing: $p" } }
function EnsureDir([string]$p) { if (-not (Test-Path -LiteralPath $p -PathType Container)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function FindSdkRoot() {
    if ($env:ANDROID_SDK_ROOT) { return $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { return $env:ANDROID_HOME }
    return (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
}
function ResolveNdkRoot() {
    if (-not [string]::IsNullOrWhiteSpace($NdkRoot)) { return [System.IO.Path]::GetFullPath($NdkRoot) }
    return (Join-Path (FindSdkRoot) "ndk\$NdkVersion")
}
function RunChecked([string]$Title, [string]$Exe, [string[]]$ArgList) {
    Write-Host "[$Title] $Exe $($ArgList -join ' ')"
    & $Exe @ArgList
    if ($LASTEXITCODE -ne 0) { Fail "$Title failed rc=$LASTEXITCODE" }
}

$ndk = ResolveNdkRoot
$hostTag = 'windows-x86_64'
$toolchain = Join-Path $ndk "toolchains\llvm\prebuilt\$hostTag"
$clang = Join-Path $toolchain 'bin\clang.exe'
$strip = Join-Path $toolchain 'bin\llvm-strip.exe'
$readelf = Join-Path $toolchain 'bin\llvm-readelf.exe'
$verify = Join-Path $ScriptDir 'verify_elf_yaw_native.ps1'
NeedFile $clang 'NDK clang.exe'
NeedFile $strip 'NDK llvm-strip.exe'
NeedFile $readelf 'NDK llvm-readelf.exe'
NeedFile $verify 'verify_elf_yaw_native.ps1'

$out = Join-Path $RootDir 'native_out'
EnsureDir (Join-Path $out 'bin')
foreach ($f in @('bindfs','mount.fuse3','mount_fusefs','magiskpolicy')) {
    $src = Join-Path $RootDir "bin\$f"
    if (Test-Path -LiteralPath $src -PathType Leaf) { Copy-Item -LiteralPath $src -Destination (Join-Path $out "bin\$f") -Force }
}

$srcMounttx = Join-Path $RootDir 'source\mounttx.c'
NeedFile $srcMounttx 'mounttx.c'
$mounttx = Join-Path $out 'bin\mounttx'
$sysroot = Join-Path $toolchain 'sysroot'
$target = "aarch64-linux-android$Api"
$alignHex = if ($PageSize -eq 16384) { '0x4000' } else { '0x1000' }
RunChecked 'build native mounttx only' $clang @(
    "--target=$target",
    "--sysroot=$sysroot",
    '-std=gnu11','-Wall','-Wextra','-Werror','-O2','-fPIE','-pie',
    "-Wl,-z,max-page-size=$PageSize",
    "-Wl,-z,common-page-size=$PageSize",
    '-o',$mounttx,$srcMounttx
)
RunChecked 'strip native mounttx' $strip @('--strip-all', $mounttx)
RunChecked 'verify native mounttx' 'powershell' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$verify,'-Readelf',$readelf,'-Binary',$mounttx,'-Mode','android-exe','-ExpectedLoadAlign',$alignHex,'-ExpectedRelroEndAlign',$alignHex,'-AllowedNeeded','libc.so,libdl.so','-RequireLibc')

Get-ChildItem -LiteralPath $out -Recurse -File | Where-Object { $_.Name -ne 'SHA256SUMS.txt' } | ForEach-Object {
    $rel = $_.FullName.Substring($out.Length).TrimStart('\').Replace('\','/')
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
    "$hash  $rel"
} | Sort-Object | Set-Content -LiteralPath (Join-Path $out 'SHA256SUMS.txt') -Encoding ASCII

$pack = Join-Path $ScriptDir 'pack_yawasau_module_windows.ps1'
NeedFile $pack 'pack_yawasau_module_windows.ps1'
if ([string]::IsNullOrWhiteSpace($OutZip)) {
    $OutZip = Join-Path (Split-Path -Parent $RootDir) 'YAWAsau_Mount_v1.4.81_remove_notify_real_id_profile_dedup_full_hotfix_20260830.zip'
}
RunChecked 'pack module with mounttx' 'powershell' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$pack,'-ModuleRoot',$RootDir,'-NativeOut',$out,'-OutZip',$OutZip,'-IncludeMagiskPolicy','-RequireClassesDex')
Write-Host "[OK] mounttx-only native rebuild completed: $OutZip"
