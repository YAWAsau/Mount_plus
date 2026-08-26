param(
    [string]$ModuleRoot = '',
    [string]$NativeOut = '',
    [string]$OutZip = '',
    [switch]$IncludeMagiskPolicy,
    [switch]$RequireClassesDex
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ModuleRoot)) { $ModuleRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir) }
$ModuleRoot = [System.IO.Path]::GetFullPath($ModuleRoot)
if ([string]::IsNullOrWhiteSpace($NativeOut)) { $NativeOut = Join-Path $ModuleRoot 'native_out' }
$NativeOut = [System.IO.Path]::GetFullPath($NativeOut)
if ([string]::IsNullOrWhiteSpace($OutZip)) {
    $OutZip = Join-Path (Split-Path -Parent $ModuleRoot) 'YAWAsau_Mount_v1.4.69_notify_result_preserve_parsed_module_20260825.zip'
}

function Fail([string]$m) { throw $m }
function NeedFile([string]$p, [string]$label) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Fail "$label missing: $p" } }
function EnsureDir([string]$p) { if (-not (Test-Path -LiteralPath $p -PathType Container)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function ResolveNativeOutFile([string]$Primary, [string]$Nested, [string]$Label) {
    if (Test-Path -LiteralPath $Primary -PathType Leaf) { return $Primary }
    if (Test-Path -LiteralPath $Nested -PathType Leaf) {
        Write-Host "[WARN] $Label found under nested native_out; using fallback: $Nested"
        return $Nested
    }
    Fail "$Label missing: $Primary ; fallback also missing: $Nested"
}
function RelPathCompat([string]$BaseDir, [string]$File) {
    # v1.4.39: PS5.1 local relative paths contain single backslashes.
    # Do not use Replace('\\','/'), which only matches double-backslash text.
    $base = [System.IO.Path]::GetFullPath($BaseDir)
    $full = [System.IO.Path]::GetFullPath($File)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if (-not $base.EndsWith([string]$sep)) { $base = $base + $sep }
    if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($base.Length).Replace([string][char]92,'/')
    }
    return $full.Replace([string][char]92,'/')
}
function AddZipFile([System.IO.Compression.ZipArchive]$Zip, [string]$BaseDir, [string]$File) {
    $rel = RelPathCompat $BaseDir $File
    if ($rel -match '^source/') { return }
    if ($rel -match '^third_party/') { return }
    if ($rel -match '^native_work/') { return }
    if ($rel -match '^native_out/') { return }
    if ($rel -match '^native/') { Fail "runtime zip must not contain native/ after v1.4.28: $rel" }
    if ($rel -match '\\') { Fail "invalid zip path separator: $rel" }
    $entry = $Zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
    $in = [System.IO.File]::OpenRead($File)
    try {
        $out = $entry.Open()
        try { $in.CopyTo($out) } finally { $out.Dispose() }
    } finally { $in.Dispose() }
}

$bindfs = ResolveNativeOutFile (Join-Path $NativeOut 'bin\bindfs') (Join-Path $NativeOut 'native_out\bin\bindfs') 'native_out\bin\bindfs'
$mountFuse3 = ResolveNativeOutFile (Join-Path $NativeOut 'bin\mount.fuse3') (Join-Path $NativeOut 'native_out\bin\mount.fuse3') 'native_out\bin\mount.fuse3'
$mountFusefs = ResolveNativeOutFile (Join-Path $NativeOut 'bin\mount_fusefs') (Join-Path $NativeOut 'native_out\bin\mount_fusefs') 'native_out\bin\mount_fusefs'
$Stage = Join-Path $ModuleRoot '.pack_stage_v1468'
if (Test-Path -LiteralPath $Stage) { Remove-Item -LiteralPath $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

$baseFiles = @('module.prop','customize.sh','service.sh','mount.sh','control.sh','action.sh','uninstall.sh','sepolicy.rule','core.sh','mount.conf.default','mount.conf.example','README.md')
foreach ($f in $baseFiles) {
    $src = Join-Path $ModuleRoot $f
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        EnsureDir (Join-Path $Stage (Split-Path -Parent $f))
        Copy-Item -LiteralPath $src -Destination (Join-Path $Stage $f) -Force
    }
}
foreach ($d in @('bin','webroot')) {
    $src = Join-Path $ModuleRoot $d
    if (Test-Path -LiteralPath $src -PathType Container) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $Stage $d) -Recurse -Force
    }
}

# Put compiled artifacts into the existing module layout, not a separate native/ directory.
EnsureDir (Join-Path $Stage 'bin')
Copy-Item -LiteralPath $bindfs -Destination (Join-Path $Stage 'bin\bindfs') -Force
Copy-Item -LiteralPath $mountFuse3 -Destination (Join-Path $Stage 'bin\mount.fuse3') -Force
Copy-Item -LiteralPath $mountFusefs -Destination (Join-Path $Stage 'bin\mount_fusefs') -Force
# v1.4.55: libfuse3 is linked statically into bindfs; do not bundle libs/libfuse3.so or lib/libfuse3.so.
$sha = Join-Path $NativeOut 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $sha -PathType Leaf) { Copy-Item -LiteralPath $sha -Destination (Join-Path $Stage 'NATIVE_SHA256SUMS.txt') -Force }

$mp = Join-Path $NativeOut 'bin\magiskpolicy'
if ($IncludeMagiskPolicy -and (Test-Path -LiteralPath $mp -PathType Leaf)) {
    Copy-Item -LiteralPath $mp -Destination (Join-Path $Stage 'bin\magiskpolicy') -Force
} elseif (Test-Path -LiteralPath $mp -PathType Leaf) {
    Write-Host '[INFO] magiskpolicy exists in native_out but was not bundled; pass -IncludeMagiskPolicy to include the official-source binary.'
}

if ($RequireClassesDex) {
    $classesDex = Join-Path $Stage 'bin\classes.dex'
    if (-not (Test-Path -LiteralPath $classesDex -PathType Leaf)) {
        Fail "Dex-only notification module requires bin/classes.dex. Run build_yawasau_full_module_windows.ps1 or build_yawasau_dex_notify_module_windows.ps1, not the source/build-kit zip."
    }
}

if (Test-Path -LiteralPath $OutZip) { Remove-Item -LiteralPath $OutZip -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [System.IO.File]::Open($OutZip, [System.IO.FileMode]::CreateNew)
try {
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        Get-ChildItem -LiteralPath $Stage -Recurse -File | ForEach-Object { AddZipFile $zip $Stage $_.FullName }
    } finally { $zip.Dispose() }
} finally { $fs.Dispose() }

$zipNames = [System.IO.Compression.ZipFile]::OpenRead($OutZip)
try {
    foreach ($entry in $zipNames.Entries) {
        if ($entry.FullName.Contains('\\')) { Fail "zip contains backslash path: $($entry.FullName)" }
        if ($entry.FullName -like 'source/*') { Fail "zip contains non-runtime source path: $($entry.FullName)" }
        if ($entry.FullName -like 'third_party/*') { Fail "zip contains non-runtime third_party path: $($entry.FullName)" }
        if ($entry.FullName -like 'native/*') { Fail "zip contains deprecated native path: $($entry.FullName)" }
    }
} finally { $zipNames.Dispose() }

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutZip).Hash.ToLowerInvariant()
Write-Host "[OK] module package created: $OutZip"
Write-Host "SHA256=$hash"
Write-Host 'Bundled runtime paths:'
Write-Host '  bin/bindfs -> /data/adb/modules/dcimswitch/bin/bindfs'
Write-Host '  libfuse3.so: not bundled; statically linked into bin/bindfs'
Write-Host '  bin/mount.fuse3 -> /data/adb/modules/dcimswitch/bin/mount.fuse3'
Write-Host '  bin/mount_fusefs -> /data/adb/modules/dcimswitch/bin/mount_fusefs'
if ($IncludeMagiskPolicy) { Write-Host '  bin/magiskpolicy -> /data/adb/modules/dcimswitch/bin/magiskpolicy' } else { Write-Host '  magiskpolicy: not bundled unless -IncludeMagiskPolicy is supplied and native_out/bin/magiskpolicy exists' }
if ($RequireClassesDex) { Write-Host '  bin/classes.dex -> /data/adb/modules/dcimswitch/bin/classes.dex (required for Dex-only notifications)' }
