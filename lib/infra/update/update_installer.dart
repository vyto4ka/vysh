import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:pointycastle/export.dart' show SHA256Digest;

import '../../infra/platform/local_files.dart';
import '../../infra/update/update_service.dart';

/// Установка обновления: скачать с проверкой SHA-256, применить, перезапустить.
///
/// * Windows portable zip: распаковка и подмена файлов PS-скриптом после
///   выхода приложения, затем перезапуск (как в keqdroid).
/// * Linux tar.gz: то же через sh-скрипт с `cp -a --remove-destination`.
/// * Android: системный установщик APK; macOS: монтирование DMG.
/// * Установщики Linux (deb/rpm/AppImage): открыть ссылку в браузере.
class UpdateInstaller {
  UpdateInstaller._();

  /// true - приложение перезапускается само (выход уже сделан).
  /// false - открыли ссылку/установщик, приложение продолжает работать.
  static Future<bool> downloadAndInstall(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    Future<void> Function()? beforeRestart,
  }) async {
    if (info.openInBrowser) {
      await LocalFiles.openUrl(info.downloadUrl);
      return false;
    }

    if (Platform.isWindows) {
      await WindowsUpdateLog.write(
        'Update requested: asset=${info.assetName}; executable=${Platform.resolvedExecutable}; appPid=$pid',
      );
    }
    final dir = await Directory.systemTemp.createTemp('vysh-update-');
    final ext = extensionFromUrl(info.downloadUrl);
    final file = File('${dir.path}${Platform.pathSeparator}vysh_update$ext');

    try {
      if (Platform.isWindows) {
        await WindowsUpdateLog.write('Downloading to ${file.path}');
      }
      await _download(info, file, onProgress);
      if (Platform.isWindows) {
        await WindowsUpdateLog.write(
          'Download complete: ${await file.length()} bytes',
        );
      }

      // Непроверенный файл не применяем.
      await _verifyDownloadedFile(file, info);
      if (Platform.isWindows) {
        await WindowsUpdateLog.write('Download verification complete');
      }

      if (Platform.isWindows && ext == '.zip') {
        return await WindowsZipUpdate.applyPortableZipUpdate(
          zipPath: file.path,
          beforeRestart: beforeRestart,
        );
      }
      if (Platform.isLinux && ext == '.tar.gz') {
        return await LinuxTarUpdate.applyPortable(
          archive: file.path,
          beforeRestart: beforeRestart,
        );
      }

      // Android: системный диалог пакетного установщика
      // «Обновить это приложение?» после скачивания с прогрессом.
      if (Platform.isAndroid && ext == '.apk') {
        await LocalFiles.installApk(file.path);
        return false;
      }

      // macOS: монтируем DMG - Finder открывает окно с vysh.app,
      // дальше пользователь переносит приложение в Applications.
      if (Platform.isMacOS && ext == '.dmg') {
        await MacOSDmgUpdate.mountDmg(file.path);
        return false;
      }

      // Неизвестная комбинация: не молчим, отдаём пользователю файл.
      await LocalFiles.openUrl(file.uri.toString());
      return false;
    } catch (error, stack) {
      if (Platform.isWindows) {
        await WindowsUpdateLog.write(
          'Update failed before handoff: $error\n$stack',
        );
      }
      // Ловим и пробрасываем; временную папку подчищаем, но на Android и
      // macOS копия файла уже у установщика/в монтированном образе.
      if (!Platform.isWindows && !Platform.isAndroid && !Platform.isMacOS) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }

  @visibleForTesting
  static String extensionFromUrl(String url) {
    final path = Uri.parse(url).path.toLowerCase();
    for (final ext in ['.tar.gz', '.zip', '.dmg', '.deb', '.rpm', '.apk']) {
      if (path.endsWith(ext)) return ext;
    }
    throw UpdateInstallException(
      UpdateInstallError.unsupportedType,
      path.split('/').last,
    );
  }

  // ── Скачивание ──

  static Future<void> _download(
    UpdateInfo info,
    File target,
    void Function(int, int)? onProgress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .getUrl(Uri.parse(info.downloadUrl))
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              client.close(force: true);
              throw const UpdateInstallException(
                UpdateInstallError.downloadFailed,
              );
            },
          );
      request.headers.set(HttpHeaders.userAgentHeader, 'vysh-updater');

      final response = await request.close().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          client.close(force: true);
          throw const UpdateInstallException(UpdateInstallError.downloadFailed);
        },
      );
      if (response.statusCode != 200) {
        throw UpdateInstallException(
          UpdateInstallError.downloadFailed,
          'HTTP ${response.statusCode}',
        );
      }

      final sink = target.openWrite();
      var received = 0;
      final total = response.contentLength;
      try {
        // Таймаут простоя: оборванное соединение без FIN иначе вешало бы
        // скачивание (и окно обновления) навсегда.
        await for (final chunk in response.timeout(
          const Duration(seconds: 60),
        )) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      // Недокачанный файл не применяем, даже если для релиза нет хеша.
      if (total > 0 && received != total) {
        throw UpdateInstallException(
          UpdateInstallError.downloadFailed,
          '$received / $total',
        );
      }
    } on UpdateInstallException {
      rethrow;
    } on SocketException catch (e) {
      throw UpdateInstallException(UpdateInstallError.downloadFailed, '$e');
    } on HttpException catch (e) {
      throw UpdateInstallException(UpdateInstallError.downloadFailed, '$e');
    } on TimeoutException {
      throw const UpdateInstallException(
        UpdateInstallError.downloadFailed,
        'timeout',
      );
    } on FileSystemException catch (e) {
      throw UpdateInstallException(UpdateInstallError.writeFailed, '$e');
    } finally {
      client.close(force: true);
    }
  }

  // ── Проверка хеша ──

  /// Проверка SHA-256. Если в релизе опубликован манифест (SHA256SUMS или
  /// `<файл>.sha256`), хеш сверяется обязательно: манифест не скачался или
  /// в нём нет нашего файла - установка отменяется. Если манифеста в
  /// релизе нет совсем (старые и ручные релизы), обновление не блокируем.
  static Future<void> _verifyDownloadedFile(File file, UpdateInfo info) async {
    final checksumUrl = info.checksumUrl;
    if (checksumUrl == null || checksumUrl.isEmpty) {
      return;
    }

    final manifest = await _fetchManifest(checksumUrl);
    final expected = parseSha256(manifest, info.assetName);
    if (expected == null) {
      throw UpdateInstallException(
        UpdateInstallError.checksumMissing,
        info.assetName,
      );
    }

    final actual = await sha256OfFile(file);
    if (actual.toLowerCase() != expected) {
      throw UpdateInstallException(
        UpdateInstallError.checksumMismatch,
        info.assetName,
      );
    }
  }

  /// SHA-256 файла потоком, без чтения целиком в память.
  static Future<String> sha256OfFile(File file) async {
    final digest = SHA256Digest();
    await for (final chunk in file.openRead()) {
      final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      digest.update(bytes, 0, bytes.length);
    }
    final full = Uint8List(digest.digestSize);
    digest.doFinal(full, 0);
    return full.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<String> _fetchManifest(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      request.headers.set(HttpHeaders.userAgentHeader, 'vysh-updater');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw UpdateInstallException(
          UpdateInstallError.downloadFailed,
          'SHA256SUMS: HTTP ${response.statusCode}',
        );
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
    } on UpdateInstallException {
      rethrow;
    } catch (e) {
      throw UpdateInstallException(
        UpdateInstallError.downloadFailed,
        'SHA256SUMS: $e',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Хеш [assetName] из манифеста формата `sha256sum`
  /// (`<hex>  <имя>` или `<hex> *<имя>`). Имя сверяется целиком, без учёта
  /// регистра. Строка без имени (файл `<имя>.sha256` с одним хешем)
  /// принимается, только если в манифесте ровно один хеш. Хеш чужого файла
  /// не подставляется никогда.
  @visibleForTesting
  static String? parseSha256(String manifest, String assetName) {
    final linePattern = RegExp(r'^\s*([a-fA-F0-9]{64})(?:\s+\*?(.*?))?\s*$');
    final lowerAsset = assetName.toLowerCase();
    final entries = <({String hash, String name})>[];

    for (final line in const LineSplitter().convert(manifest)) {
      final m = linePattern.firstMatch(line);
      if (m == null) continue;
      final name = (m.group(2) ?? '').trim();
      // В манифесте бывает путь: dist/vysh-...zip - сравниваем имя файла.
      final base = name.split(RegExp(r'[/\\]')).last.toLowerCase();
      entries.add((hash: m.group(1)!.toLowerCase(), name: base));
    }

    if (lowerAsset.isNotEmpty) {
      for (final e in entries) {
        if (e.name == lowerAsset) return e.hash;
      }
    }
    if (entries.length == 1 && entries.single.name.isEmpty) {
      return entries.single.hash;
    }
    return null;
  }
}

/// Почему установка не удалась. Текст выбирает интерфейс (l10n).
enum UpdateInstallError {
  /// Неизвестный формат файла обновления.
  unsupportedType,

  /// Скачивание не началось / прервалось / сервер ответил ошибкой.
  downloadFailed,

  /// Не удалось записать файл на диск.
  writeFailed,

  /// Для файла не опубликован SHA-256, или хеш не совпал.
  checksumMissing,
  checksumMismatch,

  /// Архив без приложения или распаковка не удалась.
  badArchive,

  /// Платформа не поддерживает такой способ установки.
  wrongPlatform,

  /// Установщик отработал, но скопировать файлы не удалось.
  copyFailed,
}

/// Ошибка установки обновления; detail - исходная причина.
class UpdateInstallException implements Exception {
  const UpdateInstallException(this.error, [this.detail]);

  final UpdateInstallError error;
  final String? detail;

  @override
  String toString() => detail == null
      ? 'UpdateInstallException(${error.name})'
      : 'UpdateInstallException(${error.name}, $detail)';
}

// ── Windows: portable zip ──

/// Подмена файлов запущенного приложения PowerShell-скриптом: дождаться
/// выхода, robocopy с повторами, перезапуск. Как в keqdroid, но для vysh.
class WindowsZipUpdate {
  WindowsZipUpdate._();

  static const exeName = 'vysh.exe';

  @visibleForTesting
  static String? findPayloadRoot(Directory extractDir) {
    final atRoot = File('${extractDir.path}${Platform.pathSeparator}$exeName');
    if (atRoot.existsSync()) return extractDir.path;

    final subdirs = extractDir
        .listSync()
        .whereType<Directory>()
        .where((d) => !d.uri.pathSegments.last.startsWith('.'))
        .toList();

    if (subdirs.length == 1) {
      final nested = File(
        '${subdirs.single.path}${Platform.pathSeparator}$exeName',
      );
      if (nested.existsSync()) return subdirs.single.path;
    }
    for (final dir in subdirs) {
      if (File('${dir.path}${Platform.pathSeparator}$exeName').existsSync()) {
        return dir.path;
      }
    }
    return null;
  }

  static Future<bool> applyPortableZipUpdate({
    required String zipPath,
    Future<void> Function()? beforeRestart,
  }) async {
    if (!Platform.isWindows) {
      throw const UpdateInstallException(
        UpdateInstallError.wrongPlatform,
        'Windows',
      );
    }

    final zipFile = File(zipPath);
    if (!await zipFile.exists()) {
      throw const UpdateInstallException(UpdateInstallError.badArchive);
    }

    final appDir = File(Platform.resolvedExecutable).parent.path;
    final exePath = Platform.resolvedExecutable;
    final staging = await zipFile.parent.createTemp('vysh_staging_');
    final extractDir = Directory('${staging.path}\\extracted');

    WindowsUpdateHandoff? handoff;
    try {
      await extractDir.create(recursive: true);
      await WindowsUpdateLog.write('Extracting $zipPath to ${extractDir.path}');
      await _extractZip(zipPath, extractDir.path);
      await WindowsUpdateLog.write('Extraction complete');

      final payloadRoot = findPayloadRoot(extractDir);
      if (payloadRoot == null) {
        throw const UpdateInstallException(
          UpdateInstallError.badArchive,
          'vysh.exe',
        );
      }

      handoff = await WindowsUpdateHandoff.start(
        staging: staging,
        sourceDir: payloadRoot,
        targetDir: appDir,
        exePath: exePath,
        appPid: pid,
        cleanupDir: zipFile.parent.path,
      );
      // Do not close the app until PowerShell has parsed, started, checked
      // permissions (including UAC), and confirmed that it can proceed.
      await handoff.waitUntilReady();
      await WindowsUpdateLog.write(
        'Installer ready; preparing to close application',
      );
      await beforeRestart?.call();
      await WindowsUpdateLog.write(
        'Confirming update handoff; application will exit',
      );
      await handoff.proceed();
    } catch (_) {
      await handoff?.cancel();
      if (handoff == null) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }

    exit(0);
  }

  static Future<void> _extractZip(String zipPath, String destination) async {
    final result =
        await Process.run(WindowsUpdateHandoff.powershellExecutable, [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          'Expand-Archive -LiteralPath '
              "'${_escapePs(zipPath)}' -DestinationPath "
              "'${_escapePs(destination)}' -Force",
        ]);
    if (result.exitCode != 0) {
      final message = (result.stderr as String).trim();
      throw UpdateInstallException(
        UpdateInstallError.badArchive,
        message.isEmpty ? null : message,
      );
    }
  }

  static String _escapePs(String value) => value.replaceAll("'", "''");

  @visibleForTesting
  static String updaterScript() => r'''
param(
  [Parameter(Mandatory = $true)][string]$SourceDir,
  [Parameter(Mandatory = $true)][string]$TargetDir,
  [Parameter(Mandatory = $true)][string]$ExePath,
  [Parameter(Mandatory = $true)][int]$AppPid,
  [Parameter(Mandatory = $true)][string]$CleanupDir,
  [Parameter(Mandatory = $true)][string]$StatusFile,
  [Parameter(Mandatory = $true)][string]$ProceedFile,
  [Parameter(Mandatory = $true)][string]$CancelFile,
  [Parameter(Mandatory = $true)][string]$LogFile,
  [switch]$NoErrorDialog
)

$ErrorActionPreference = 'Stop'
$log = $LogFile
function Log($m) {
  try { "$(Get-Date -Format o)  $m" | Out-File -FilePath $log -Append -Encoding utf8 } catch {}
}
Log "=== update start: source=$SourceDir target=$TargetDir exe=$ExePath pid=$AppPid"

function Status([string]$state, [string]$detail = '') {
  $tmp = $StatusFile + '.tmp'
  @{state=$state; detail=$detail} | ConvertTo-Json -Compress |
    Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $StatusFile -Force
}
function Fail([string]$message) {
  Log $message
  try { Status 'failed' $message } catch {}
  if (-not $NoErrorDialog -and (Test-Path -LiteralPath $ProceedFile)) {
    try {
      Add-Type -AssemblyName System.Windows.Forms
      [void][System.Windows.Forms.MessageBox]::Show(
        "vysh update failed. Downloaded files were kept in: $CleanupDir`nLog: $log`n$message", 'vysh update')
    } catch {}
  }
  exit 1
}

try {
if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'vysh.exe') -PathType Leaf)) {
  throw 'Update archive does not contain vysh.exe'
}
if (Test-Path -LiteralPath $CancelFile) { exit 1 }

# 2) если в папку установки нельзя писать (Program Files) - перезапуск
#    скрипта с повышением прав.
$writable = $false
try {
  $probe = Join-Path $TargetDir ('.upd_' + [System.Guid]::NewGuid().ToString('N'))
  [System.IO.File]::WriteAllText($probe, 'x')
  Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
  $writable = $true
} catch { $writable = $false }

$isAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $writable -and -not $isAdmin) {
  Log "target not writable; relaunching elevated"
  Status 'elevating'
  # PowerShell 5.1 склеивает массив -ArgumentList через пробел без кавычек:
  # путь "C:\Program Files\vysh" развалился бы на части. Собираем строку
  # сами; хвостовые \ удваиваются, чтобы не экранировать закрывающую кавычку.
  function Quote([string]$s) { '"' + ($s -replace '(\\+)$', '$1$1') + '"' }
  $argLine = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', (Quote $PSCommandPath),
    '-SourceDir', (Quote $SourceDir),
    '-TargetDir', (Quote $TargetDir),
    '-ExePath', (Quote $ExePath),
    '-AppPid', $AppPid,
    '-CleanupDir', (Quote $CleanupDir),
    '-StatusFile', (Quote $StatusFile),
    '-ProceedFile', (Quote $ProceedFile),
    '-CancelFile', (Quote $CancelFile),
    '-LogFile', (Quote $LogFile)
  ) -join ' '
  if ($NoErrorDialog) { $argLine += ' -NoErrorDialog' }
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argLine
    exit 0
  } catch {
    Fail "elevation failed: $_"
  }
}

if (-not $writable) { throw "Target directory is not writable: $TargetDir" }
if (Test-Path -LiteralPath $CancelFile) { exit 1 }
Status 'ready'
Log 'ready; waiting for application handoff'

# The main app can still cancel (for example, saving settings failed).
$deadline = (Get-Date).AddSeconds(120)
while (-not (Test-Path -LiteralPath $ProceedFile)) {
  if (Test-Path -LiteralPath $CancelFile) { Log 'handoff cancelled'; exit 1 }
  if ((Get-Date) -gt $deadline) { throw 'Application did not confirm update handoff' }
  Start-Sleep -Milliseconds 100
}

# Only replace files after the old process has actually exited.
$deadline = (Get-Date).AddSeconds(120)
while (Get-Process -Id $AppPid -ErrorAction SilentlyContinue) {
  if (Test-Path -LiteralPath $CancelFile) { exit 1 }
  if ((Get-Date) -gt $deadline) { throw 'Application is still running; update cancelled' }
  Start-Sleep -Milliseconds 200
}
Start-Sleep -Seconds 1
if (Test-Path -LiteralPath $CancelFile) { exit 1 }

# /IM is not available on older Windows 10 robocopy versions.
# Capture the actual output and require a valid success exit code.
$copied = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
  & robocopy.exe $SourceDir $TargetDir /E /IS /IT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1 |
    Out-File -FilePath $log -Append -Encoding utf8
  $code = $LASTEXITCODE
  Log "robocopy attempt $attempt exit=$code"
  if ($null -ne $code -and $code -ge 0 -and $code -lt 8) { $copied = $true; break }
  Start-Sleep -Seconds 1
}
if (-not $copied) { throw 'Update copy failed after retries' }

# Check every payload file before launching, not just robocopy's exit code.
foreach ($file in Get-ChildItem -LiteralPath $SourceDir -File -Recurse) {
  $relative = $file.FullName.Substring($SourceDir.TrimEnd('\').Length).TrimStart('\')
  $installed = Join-Path $TargetDir $relative
  if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne
      (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash) {
    throw "Installed file does not match update: $relative"
  }
}
Log 'all installed files verified'
$child = Start-Process -FilePath $ExePath -WorkingDirectory $TargetDir -PassThru
Start-Sleep -Milliseconds 500
$child.Refresh()
if ($child.HasExited) { throw "New application exited immediately with code $($child.ExitCode)" }
Log "relaunched $ExePath pid=$($child.Id)"
Status 'complete' "$($child.Id)"
Start-Sleep -Seconds 2
# Only remove the verified download and script after successful installation.
Remove-Item -LiteralPath $CleanupDir -Recurse -Force -ErrorAction SilentlyContinue
} catch {
  Fail "update failed: $_"
}
''';
}

/// Written by Dart before PowerShell starts, so startup failures leave diagnostics too.
class WindowsUpdateLog {
  WindowsUpdateLog._();
  static File get file => File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}vysh_update.log',
  );
  static Future<void> write(String message) async {
    try {
      await file.writeAsString(
        '${DateTime.now().toIso8601String()} [app] $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      /* Diagnostics must not hide the original installer error. */
    }
  }
}

/// Two-phase handoff: a launched process alone is not evidence of a ready installer.
class WindowsUpdateHandoff {
  WindowsUpdateHandoff(this.statusFile, this.proceedFile, this.cancelFile);
  final File statusFile;
  final File proceedFile;
  final File cancelFile;
  int? _exitCode;

  static String get powershellExecutable {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    return '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  }

  static Future<WindowsUpdateHandoff> start({
    required Directory staging,
    required String sourceDir,
    required String targetDir,
    required String exePath,
    required int appPid,
    required String cleanupDir,
    bool noErrorDialog = false,
  }) async {
    final sep = Platform.pathSeparator;
    final handoff = WindowsUpdateHandoff(
      File('${staging.path}${sep}status.json'),
      File('${staging.path}${sep}proceed'),
      File('${staging.path}${sep}cancel'),
    );
    final script = File('${staging.path}${sep}apply_update.ps1');
    await script.writeAsString(
      '\u{FEFF}${WindowsZipUpdate.updaterScript()}',
      flush: true,
    );
    final validation = await Process.run(
      powershellExecutable,
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        r'$tokens = $null; $errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:VYSH_UPDATE_SCRIPT, [ref]$tokens, [ref]$errors); if ($errors.Count -gt 0) { $errors | Out-String | Write-Error; exit 1 }',
      ],
      environment: {'VYSH_UPDATE_SCRIPT': script.path},
    );
    if (validation.exitCode != 0) {
      await WindowsUpdateLog.write(
        'PowerShell validation failed: ${validation.stdout} ${validation.stderr}',
      );
      throw UpdateInstallException(
        UpdateInstallError.copyFailed,
        '${validation.stderr}',
      );
    }
    await WindowsUpdateLog.write('PowerShell script syntax verified');
    await WindowsUpdateLog.write(
      'Starting PowerShell helper: $powershellExecutable; script=${script.path}; source=$sourceDir; target=$targetDir',
    );
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final invocation = [
      '&',
      quote(script.path.replaceAll('/', r'\')),
      '-SourceDir',
      quote(sourceDir.replaceAll('/', r'\')),
      '-TargetDir',
      quote(targetDir.replaceAll('/', r'\')),
      '-ExePath',
      quote(exePath.replaceAll('/', r'\')),
      '-AppPid',
      '$appPid',
      '-CleanupDir',
      quote(cleanupDir.replaceAll('/', r'\')),
      '-StatusFile',
      quote(handoff.statusFile.path.replaceAll('/', r'\')),
      '-ProceedFile',
      quote(handoff.proceedFile.path.replaceAll('/', r'\')),
      '-CancelFile',
      quote(handoff.cancelFile.path.replaceAll('/', r'\')),
      '-LogFile',
      quote(WindowsUpdateLog.file.path),
      if (noErrorDialog) '-NoErrorDialog',
    ].join(' ');
    // One UTF-16LE argument avoids the additional Windows/PowerShell -File
    // command-line parsing layer, including spaces, apostrophes and Cyrillic.
    final encoded = base64Encode([
      for (final unit in invocation.codeUnits) ...[unit & 255, unit >> 8],
    ]);
    final process = await Process.start(powershellExecutable, [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      encoded,
    ], mode: ProcessStartMode.normal);
    // On Windows normal mode uses CREATE_NO_WINDOW and does not terminate
    // children when the parent exits. DETACHED_PROCESS prevents Windows
    // PowerShell from starting reliably; keep the startup streams instead.
    unawaited(
      process.exitCode.then((code) async {
        handoff._exitCode = code;
        await WindowsUpdateLog.write('PowerShell helper exited: code=$code');
      }),
    );
    await process.stdin.close();
    for (final output in [process.stdout, process.stderr]) {
      output
          .transform(systemEncoding.decoder)
          .listen(
            (text) =>
                unawaited(WindowsUpdateLog.write('PowerShell output: $text')),
            onError: (Object error) => unawaited(
              WindowsUpdateLog.write('PowerShell output error: $error'),
            ),
          );
    }
    await WindowsUpdateLog.write(
      'PowerShell helper spawned: pid=${process.pid}; awaiting readiness',
    );
    return handoff;
  }

  Future<void> waitUntilReady({
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final timer = Stopwatch()..start();
    while (timer.elapsed < timeout) {
      if (await statusFile.exists()) {
        final raw = (await statusFile.readAsString()).replaceFirst(
          '\u{FEFF}',
          '',
        );
        final status = jsonDecode(raw) as Map<String, dynamic>;
        if (status['state'] == 'ready') return;
        if (status['state'] == 'elevating') {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          continue;
        }
        throw UpdateInstallException(
          UpdateInstallError.copyFailed,
          '${status['detail']}',
        );
      }
      if (_exitCode != null) {
        throw UpdateInstallException(
          UpdateInstallError.copyFailed,
          'PowerShell exited before readiness (code $_exitCode). See %TEMP%\\vysh_update.log',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const UpdateInstallException(
      UpdateInstallError.copyFailed,
      'Windows updater did not start. See %TEMP%\\vysh_update.log',
    );
  }

  Future<void> proceed() async {
    await proceedFile.writeAsString('proceed', flush: true);
  }

  Future<void> cancel() async {
    try {
      await cancelFile.writeAsString('cancel', flush: true);
    } catch (_) {}
  }
}

// ── Linux: portable tar.gz ──

/// Обновление портативной сборки: распаковать tar.gz и скопировать поверх
/// через sh-скрипт после выхода (в запущенный файл Linux писать не даёт,
/// `--remove-destination` обходит это удалением + копированием).
class LinuxTarUpdate {
  LinuxTarUpdate._();

  static const exeName = 'vysh';

  @visibleForTesting
  static String? findPayloadRoot(Directory extractDir) {
    final atRoot = File('${extractDir.path}/$exeName');
    if (atRoot.existsSync()) return extractDir.path;
    for (final dir in extractDir.listSync().whereType<Directory>()) {
      if (File('${dir.path}/$exeName').existsSync()) return dir.path;
    }
    return null;
  }

  static Future<bool> applyPortable({
    required String archive,
    Future<void> Function()? beforeRestart,
  }) async {
    if (!Platform.isLinux) {
      throw const UpdateInstallException(
        UpdateInstallError.wrongPlatform,
        'Linux',
      );
    }

    final appDir = File(Platform.resolvedExecutable).parent.path;
    // Скрипт копирует уже после выхода приложения: если в папку программы
    // писать нельзя (/opt, /usr, AppImage), cp упадёт, и запустится старая
    // версия без единого сообщения. Проверяем заранее, пока можно показать
    // ошибку.
    if (!await _isWritable(appDir)) {
      throw UpdateInstallException(UpdateInstallError.copyFailed, appDir);
    }
    final staging = await Directory.systemTemp.createTemp('vysh-update-');
    try {
      final result = await Process.run('tar', [
        '-xzf',
        archive,
        '-C',
        staging.path,
      ]);
      if (result.exitCode != 0) {
        throw UpdateInstallException(
          UpdateInstallError.badArchive,
          _tail(result.stderr),
        );
      }

      final payload = findPayloadRoot(staging);
      if (payload == null) {
        throw const UpdateInstallException(
          UpdateInstallError.badArchive,
          'vysh',
        );
      }

      await _launchAfterExit(_portableScript, [
        payload,
        appDir,
        staging.path,
        archive,
      ]);
    } catch (_) {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }

    await beforeRestart?.call();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  static Future<bool> _isWritable(String dir) async {
    try {
      final probe = File('$dir/.vysh_update_probe_$pid');
      await probe.writeAsString('x', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  static String? _tail(Object? stderr) {
    final lines = '$stderr'
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    return lines.skip(lines.length > 3 ? lines.length - 3 : 0).join('\n');
  }

  // ARCHIVE лежит в своей временной папке vysh-update-* - удаляем её
  // целиком, вместе со скриптом.
  static const _portableScript = r'''
SRC="$1"; DST="$2"; STAGING="$3"; ARCHIVE="$4"
log "=== portable update: $SRC -> $DST"
if cp -a --remove-destination "$SRC/." "$DST/" 2>>"$LOG"; then
  log "copied"
else
  log "copy FAILED"
fi
rm -rf "$STAGING" "$(dirname "$ARCHIVE")" 2>/dev/null
rm -f "$0" 2>/dev/null
setsid "$DST/vysh" >/dev/null 2>&1 < /dev/null &
''';

  /// setsid уводит процесс из нашей группы, чтобы exit(0) его не прихватил.
  static Future<void> _launchAfterExit(String body, List<String> args) async {
    final script = File(
      '${Directory.systemTemp.path}/vysh_update_'
      '${DateTime.now().millisecondsSinceEpoch}.sh',
    );
    await script.writeAsString('$_waitForApp\n$body');
    final shArgs = [script.path, '$pid', ...args];
    try {
      await Process.start('setsid', [
        'sh',
        ...shArgs,
      ], mode: ProcessStartMode.detached);
    } on ProcessException {
      await Process.start('sh', shArgs, mode: ProcessStartMode.detached);
    }
  }

  static const _waitForApp = r'''
APPPID="$1"; shift
LOG="${TMPDIR:-/tmp}/vysh_update.log"
log() { printf '%s  %s\n' "$(date -Is 2>/dev/null)" "$1" >>"$LOG" 2>/dev/null; }
i=0
while [ "$i" -lt 120 ]; do
  kill -0 "$APPPID" 2>/dev/null || break
  sleep 1
  i=$((i+1))
done
sleep 1
''';
}

// ── macOS: DMG ──

/// Обновление на macOS: смонтировать скачанный DMG через `hdiutil attach` -
/// Finder открывает окно с vysh.app и ссылкой на /Applications, дальше
/// пользователь переносит приложение (стандартный UX установки на macOS).
/// Приложение продолжает работать: подмена запущенного .app на macOS
/// возможна, но требует отключения Gatekeeper-проверок и права на запись
/// в /Applications - система надёжнее.
class MacOSDmgUpdate {
  MacOSDmgUpdate._();

  static Future<void> mountDmg(String dmgPath) async {
    final result = await Process.run('hdiutil', [
      'attach',
      '-noverify',
      '-noautoopen',
      dmgPath,
    ]);
    if (result.exitCode != 0) {
      final message = (result.stderr as String).trim();
      throw UpdateInstallException(
        UpdateInstallError.badArchive,
        message.isEmpty ? null : message,
      );
    }
    // В Finder окно образа открывает сам hdiutil при монтировании без
    // -noautoopen; с ним открываем вручную, чтобы пользователь увидел
    // vysh.app сразу.
    final mountPoint = mountPointOf(result.stdout as String);
    if (mountPoint != null) {
      await Process.start('open', [
        mountPoint,
      ], mode: ProcessStartMode.detached);
    }
  }

  /// stdout hdiutil: таблица смонтированных разделов, точка монтирования -
  /// последняя колонка (колонки разделены табуляцией) строки вида:
  /// `/dev/disk4s1  Apple_HFS  /Volumes/vysh`. В имени тома бывают
  /// пробелы (`/Volumes/vysh 0.5`), поэтому берём всё от `/Volumes/` до
  /// конца строки, а не последнее «слово».
  @visibleForTesting
  static String? mountPointOf(String stdout) {
    final lines = stdout
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
    for (final line in lines.reversed) {
      final at = line.indexOf('/Volumes/');
      if (at >= 0) return line.substring(at);
    }
    return null;
  }
}
