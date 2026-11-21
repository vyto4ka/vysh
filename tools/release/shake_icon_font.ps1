# Replace the full 1.6 MB MaterialIcons font in a Windows release bundle with
# the tree-shaken one (~20-30 KB).
# (ASCII only: Windows PowerShell 5.1 misreads UTF-8 without BOM)
#
# `flutter build windows` never shakes the icon font because CMake passes
# -dTreeShakeIcons="true" with literal quotes to `flutter assemble`, which
# compares `"true"` to `true` and skips the shaker.
param([Parameter(Mandatory = $true)][string]$BundleDir)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$font = 'data\flutter_assets\fonts\MaterialIcons-Regular.otf'
$dest = Join-Path $BundleDir $font
if (-not (Test-Path -LiteralPath $dest)) { throw "No icon font in bundle: $dest" }

$configPath = Join-Path $repoRoot 'windows\flutter\ephemeral\generated_config.cmake'
$config = Get-Content -LiteralPath $configPath -Raw
function Get-ToolEnv([string]$name) {
  if ($config -notmatch ('"' + $name + '=([^"]*)"')) {
    throw "$name not found in $configPath - run flutter build windows first"
  }
  return $Matches[1].Replace('\\', '\')
}

Push-Location $repoRoot
try {
  & flutter assemble --no-version-check --output=build `
    -dTargetPlatform=windows-x64 `
    "-dTrackWidgetCreation=$(Get-ToolEnv 'TRACK_WIDGET_CREATION')" `
    -dBuildMode=release `
    "-dTargetFile=$(Get-ToolEnv 'FLUTTER_TARGET')" `
    -dTreeShakeIcons=true `
    "-dDartObfuscation=$(Get-ToolEnv 'DART_OBFUSCATION')" `
    "--DartDefines=$(Get-ToolEnv 'DART_DEFINES')" `
    release_bundle_windows-x64_assets
  if ($LASTEXITCODE -ne 0) { throw 'flutter assemble failed' }
}
finally { Pop-Location }

$shaken = Join-Path $repoRoot 'build\flutter_assets\fonts\MaterialIcons-Regular.otf'
$before = (Get-Item -LiteralPath $dest).Length
$after = (Get-Item -LiteralPath $shaken).Length
if ($after -ge $before) { throw "Icon font was not shaken ($after >= $before bytes)" }
Copy-Item -LiteralPath $shaken -Destination $dest -Force
Write-Host ("    icon font: {0:N0} -> {1:N0} bytes" -f $before, $after)
