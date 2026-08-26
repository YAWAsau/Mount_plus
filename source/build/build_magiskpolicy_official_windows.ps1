param(
    [string]$MagiskSrc = '',
    [string]$MagiskRef = '',
    [string]$NdkVersion = '28.2.13676358',
    [string]$NdkRoot = '',
    [string]$Python = 'auto',
    [switch]$SetupMagiskNdk,
    [switch]$NoFetchMagisk,
    [switch]$PackModule,
    [switch]$IncludeMagiskPolicy,
    [string]$ModuleZipOut = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = Join-Path $ScriptDir 'build_yawasau_native_windows.ps1'
if (-not (Test-Path -LiteralPath $build -PathType Leaf)) { throw "build_yawasau_native_windows.ps1 not found: $build" }
$args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$build,'-SkipBindfs','-BuildMagiskPolicy','-NdkVersion',$NdkVersion,'-Python',$Python)
if (-not [string]::IsNullOrWhiteSpace($NdkRoot)) { $args += @('-NdkRoot',$NdkRoot) }
if (-not [string]::IsNullOrWhiteSpace($MagiskSrc)) { $args += @('-MagiskSrc',$MagiskSrc) }
if (-not [string]::IsNullOrWhiteSpace($MagiskRef)) { $args += @('-MagiskRef',$MagiskRef) }
if ($NoFetchMagisk) { $args += @('-NoFetchMagisk') }
if ($SetupMagiskNdk) { $args += @('-SetupMagiskNdk') }
if ($PackModule) { $args += @('-PackModule') }
if ($IncludeMagiskPolicy) { $args += @('-IncludeMagiskPolicy') }
if (-not [string]::IsNullOrWhiteSpace($ModuleZipOut)) { $args += @('-ModuleZipOut',$ModuleZipOut) }
& powershell @args
exit $LASTEXITCODE
