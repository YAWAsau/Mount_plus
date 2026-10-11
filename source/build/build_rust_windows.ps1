param(
    [string]$NdkRoot = "$env:LOCALAPPDATA/Android/Sdk/ndk/30.0.16248370",
    [string]$OutDir = '',
    [switch]$Tests
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Project = Join-Path $Root 'source/mountctl'
if (!(Test-Path "$NdkRoot/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe")) { throw 'NDK toolchain missing' }
if ((Get-Content "$NdkRoot/source.properties" -Raw) -notmatch 'Pkg.Revision\s*=\s*30\.') { throw 'NDK r30 required' }
if (!$OutDir) { $OutDir = Join-Path $Root 'bin' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "$NdkRoot/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe"
$env:RUSTFLAGS = '-C link-arg=--target=aarch64-linux-android28 -C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384'
Push-Location $Project
try {
    cargo build --offline --locked --release --target aarch64-linux-android
    if ($LASTEXITCODE) { throw 'Rust build failed' }
    cargo clippy --offline --locked --release --target aarch64-linux-android -- -D warnings
    if ($LASTEXITCODE) { throw 'Rust lint failed' }
    if ($Tests) {
        cargo test --offline --locked --release --target aarch64-linux-android --no-run
        if ($LASTEXITCODE) { throw 'Rust test build failed' }
    }
} finally { Pop-Location }
# Android customize.sh creates compatibility symlinks to one physical ELF.
Copy-Item "$Project/target/aarch64-linux-android/release/mountctl" (Join-Path $OutDir 'mounttx') -Force
foreach ($Name in @('confwatch','propwait','mount.fuse3','mount_fusefs')) {
    $OldAlias = Join-Path $OutDir $Name
    if (Test-Path -LiteralPath $OldAlias) { Remove-Item -LiteralPath $OldAlias -Force }
}
