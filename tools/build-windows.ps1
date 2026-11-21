# Build vysh zip for Windows (unpack and run, no installer).
# Run from project root:
#   powershell -ExecutionPolicy Bypass -File tools\build-windows.ps1
# Output: dist\vysh-<version>-windows-x64.zip
# (ASCII only on purpose: Windows PowerShell 5.1 misreads UTF-8 without BOM)

$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)

# Version from pubspec.yaml ("version: 0.1.0+1" -> 0.1.0)
$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([^\s+]+)').Matches[0].Groups[1].Value
Write-Host "==> vysh $version" -ForegroundColor Cyan

# Build date for "About" = last commit time. Not the current time: it is part
# of the Dart build key, so every run would rebuild everything (~100s vs ~20s).
$buildDate = git log -1 '--date=format-local:%d.%m.%y %H:%M:%S' --format=%cd
if ($LASTEXITCODE -ne 0 -or -not $buildDate) { $buildDate = Get-Date -Format 'dd.MM.yy HH:mm:ss' }

Write-Host "==> flutter build windows --release ($buildDate)" -ForegroundColor Cyan
flutter build windows --release "--dart-define=BUILD_DATE=$buildDate"
if ($LASTEXITCODE -ne 0) { throw "flutter build failed" }

$src = "build\windows\x64\runner\Release"
$out = "dist\vysh-$version-windows-x64"
$zip = "$out.zip"

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
if (Test-Path $zip) { Remove-Item $zip -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null
Copy-Item "$src\*" $out -Recurse

# MSVC runtime next to exe: runs without VC++ Redistributable installed.
foreach ($dll in "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll") {
  $p = Join-Path $env:WINDIR "System32\$dll"
  if (Test-Path $p) { Copy-Item $p $out } else { Write-Warning "$dll not found" }
}

# User data (hosts, settings) lives in %APPDATA%\vysh, not here,
# so updating = delete old folder, unpack new one.

# GPL text ships with every copy.
Copy-Item LICENSE $out

Compress-Archive -Path "$out\*" -DestinationPath $zip
Write-Host "==> Done:" -ForegroundColor Green
Write-Host "    folder: $out"
Write-Host "    zip:    $zip"
