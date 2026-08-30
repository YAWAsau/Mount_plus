param(
  [string]$JavaHome = 'C:\Program Files\Android\Android Studio\jbr',
  [string]$SdkPath = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
  [switch]$SkipDexBuild,
  [switch]$PackOnly
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ModuleRoot = $Root
$DexRoot = Join-Path $Root 'source\dex_notify'
$OutZip = Join-Path $Root 'YAWAsau_Mount_v1.4.70_fast_unlock_mount_module_20260826.zip'
if (!$PackOnly -and !$SkipDexBuild) {
  if (!(Test-Path -LiteralPath $JavaHome)) { throw "JAVA_HOME not found: $JavaHome" }
  if (!(Test-Path -LiteralPath $SdkPath)) { throw "Android SDK not found: $SdkPath" }
  $env:JAVA_HOME = $JavaHome
  $sdkForward = $SdkPath.Replace('\','/')
  [IO.File]::WriteAllText((Join-Path $DexRoot 'local.properties'), 'sdk.dir=' + $sdkForward)
  Write-Host "[INFO] JAVA_HOME=$env:JAVA_HOME" -ForegroundColor Cyan
  Write-Host "[INFO] sdk.dir=$sdkForward" -ForegroundColor Cyan
  Push-Location $DexRoot
  try {
    & (Join-Path $DexRoot 'gradlew.bat') ':app:assembleRelease'
    if ($LASTEXITCODE -ne 0) { throw "Gradle dex build failed rc=$LASTEXITCODE" }
  } finally { Pop-Location }
  $apk = Get-ChildItem -LiteralPath (Join-Path $DexRoot 'app\build\outputs\apk\release') -Filter '*.apk' -File | Select-Object -First 1
  if (!$apk) { throw 'release APK not found after Dex build' }
  $tmp = Join-Path $Root '.dex_extract'
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'app-release.zip'
  Copy-Item -LiteralPath $apk.FullName -Destination $zip -Force
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
  $dex = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'classes.dex' -File | Select-Object -First 1
  if (!$dex) { throw 'classes.dex not found inside release APK' }
  New-Item -ItemType Directory -Force -Path (Join-Path $ModuleRoot 'bin') | Out-Null
  Copy-Item -LiteralPath $dex.FullName -Destination (Join-Path $ModuleRoot 'bin\classes.dex') -Force
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  $dh = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $ModuleRoot 'bin\classes.dex')).Hash.ToLowerInvariant()
  Write-Host "[OK] Dex copied to module/bin/classes.dex SHA256=$dh" -ForegroundColor Green
}
& (Join-Path $PSScriptRoot 'pack_yawasau_module_windows.ps1') -ModuleRoot $ModuleRoot -OutZip $OutZip -IncludeMagiskPolicy -RequireClassesDex
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipCheck = [System.IO.Compression.ZipFile]::OpenRead($OutZip)
try {
  $hasDex = $false
  foreach ($entry in $zipCheck.Entries) { if ($entry.FullName -eq 'bin/classes.dex') { $hasDex = $true; break } }
  if (-not $hasDex) { throw 'final module zip missing bin/classes.dex' }
} finally { $zipCheck.Dispose() }
Write-Host '[OK] final module contains bin/classes.dex' -ForegroundColor Green
