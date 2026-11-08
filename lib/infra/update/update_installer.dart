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
/// * Android / macOS / установщики Linux: открыть страницу релиза.
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

    final dir = await Directory.systemTemp.createTemp('vysh-update-');
    final ext = extensionFromUrl(info.downloadUrl);
    final file = File('${dir.path}${Platform.pathSeparator}vysh_update$ext');

    try {
      await _download(info, file, onProgress);

      // Непроверенный файл не применяем.
      await _verifyDownloadedFile(file, info);

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
    } catch (_) {
      // Ловим и пробрасываем; временную папку подчищаем, но на Android и
      // macOS копия файла уже у установщика/в монтированном образе.
      if (!Platform.isAndroid && !Platform.isMacOS) {
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
      UpdateInstallError.unsupportedType, path.split('/').last
    );
  }

  // ── Скачивание ──

  static Future<void> _download(
    UpdateInfo info,
    File target,
    void Function(int, int)? onProgress,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .getUrl(Uri.parse(info.downloadUrl))
          .timeout(const Duration(seconds: 15), onTimeout: () {
        client.close(force: true);
        throw const UpdateInstallException(UpdateInstallError.downloadFailed);
      });
      request.headers.set(HttpHeaders.userAgentHeader, 'vysh-updater');

      final response = await request.close().timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          client.close(force: true);
          throw const UpdateInstallException(UpdateInstallError.downloadFailed);
        },
      );
      if (response.statusCode != 200) {
        throw UpdateInstallException(UpdateInstallError.downloadFailed, 'HTTP ${response.statusCode}');
      }

      final sink = target.openWrite();
      var received = 0;
      final total = response.contentLength;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } on UpdateInstallException {
      rethrow;
    } on SocketException catch (e) {
      throw UpdateInstallException(UpdateInstallError.downloadFailed, '$e');
    } on FileSystemException catch (e) {
      throw UpdateInstallException(UpdateInstallError.writeFailed, '$e');
    } finally {
      client.close(force: true);
    }
  }

  // ── Проверка хеша ──

  /// Без опубликованного SHA-256 не ставим: ссылка на файл могла подмениться.
  static Future<void> _verifyDownloadedFile(File file, UpdateInfo info) async {
    final checksumUrl = info.checksumUrl;
    if (checksumUrl == null || checksumUrl.isEmpty) {
      throw UpdateInstallException(
        UpdateInstallError.checksumMissing, info.assetName
      );
    }

    final expected = await _fetchExpectedSha256(checksumUrl, info.assetName);
    if (expected == null) {
      throw UpdateInstallException(
        UpdateInstallError.checksumMissing, info.assetName
      );
    }

    final actual = await sha256OfFile(file);
    if (actual.toLowerCase() != expected) {
      throw UpdateInstallException(
        UpdateInstallError.checksumMismatch, info.assetName
      );
    }
  }

  static Future<String> sha256OfFile(File file) async {
    final digest = SHA256Digest();
    final bytes = await file.readAsBytes();
    // Чанками, чтобы не держать весь файл в памяти.
    const chunkSize = 1 << 20;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize).clamp(0, bytes.length);
      final chunk = Uint8List.sublistView(bytes, offset, end);
      digest.update(chunk, 0, chunk.length);
    }
    final full = Uint8List(digest.digestSize);
    var off = 0;
    while (off < full.length) {
      final n = digest.doFinal(full, off);
      off += n;
    }
    return full.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<String?> _fetchExpectedSha256(
    String url,
    String assetName,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'vysh-updater');
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      final text = await response.transform(utf8.decoder).join();
      return parseSha256(text, assetName);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  @visibleForTesting
  static String? parseSha256(String manifest, String assetName) {
    final hexPattern = RegExp(r'\b[a-fA-F0-9]{64}\b');
    final lowerAsset = assetName.toLowerCase();

    if (lowerAsset.isNotEmpty) {
      for (final line in const LineSplitter().convert(manifest)) {
        if (line.toLowerCase().contains(lowerAsset)) {
          final m = hexPattern.firstMatch(line);
          if (m != null) return m.group(0)!.toLowerCase();
        }
      }
    }

    final m = hexPattern.firstMatch(manifest);
    return m?.group(0)?.toLowerCase();
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
    final atRoot = File('${extractDir.path}\\$exeName');
    if (atRoot.existsSync()) return extractDir.path;

    final subdirs = extractDir
        .listSync()
        .whereType<Directory>()
        .where((d) => !d.uri.pathSegments.last.startsWith('.'))
        .toList();

    if (subdirs.length == 1) {
      final nested = File('${subdirs.single.path}\\$exeName');
      if (nested.existsSync()) return subdirs.single.path;
    }
    for (final dir in subdirs) {
      if (File('${dir.path}\\$exeName').existsSync()) return dir.path;
    }
    return null;
  }

  static Future<bool> applyPortableZipUpdate({
    required String zipPath,
    Future<void> Function()? beforeRestart,
  }) async {
    if (!Platform.isWindows) {
      throw const UpdateInstallException(UpdateInstallError.wrongPlatform, 'Windows');
    }

    final zipFile = File(zipPath);
    if (!await zipFile.exists()) {
      throw const UpdateInstallException(UpdateInstallError.badArchive);
    }

    final appDir = File(Platform.resolvedExecutable).parent.path;
    final exePath = Platform.resolvedExecutable;
    final staging = await zipFile.parent.createTemp('vysh_staging_');
    final extractDir = Directory('${staging.path}\\extracted');

    try {
      await extractDir.create(recursive: true);
      await _extractZip(zipPath, extractDir.path);

      final payloadRoot = findPayloadRoot(extractDir);
      if (payloadRoot == null) {
        throw const UpdateInstallException(
          UpdateInstallError.badArchive, 'vysh.exe'
        );
      }

      final scriptPath = '${staging.path}\\apply_update.ps1';
      // BOM обязателен: PowerShell 5.1 без него читает .ps1 в ANSI
      // и ломает не-ASCII символы.
      await File(scriptPath).writeAsString(
        '\u{FEFF}${_updaterScript()}',
        flush: true,
      );

      // Вне нашего дерева процессов, чтобы пережил exit.
      await Process.start(
        'cmd.exe',
        [
          '/c', 'start', '""', '/min', 'powershell.exe',
          '-NoProfile', '-ExecutionPolicy', 'Bypass',
          '-WindowStyle', 'Hidden', '-File', scriptPath,
          '-SourceDir', payloadRoot,
          '-TargetDir', appDir,
          '-ExePath', exePath,
          '-AppPid', '$pid',
          '-CleanupDir', staging.path,
        ],
        mode: ProcessStartMode.detached,
      );
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

  static Future<void> _extractZip(String zipPath, String destination) async {
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
        'Expand-Archive -LiteralPath '
        "'${_escapePs(zipPath)}' -DestinationPath "
        "'${_escapePs(destination)}' -Force",
      ],
    );
    if (result.exitCode != 0) {
      final message = (result.stderr as String).trim();
      throw UpdateInstallException(
        UpdateInstallError.badArchive, message.isEmpty ? null : message,
      );
    }
  }

  static String _escapePs(String value) => value.replaceAll("'", "''");

  static String _updaterScript() => r'''
param(
  [Parameter(Mandatory = $true)][string]$SourceDir,
  [Parameter(Mandatory = $true)][string]$TargetDir,
  [Parameter(Mandatory = $true)][string]$ExePath,
  [Parameter(Mandatory = $true)][int]$AppPid,
  [Parameter(Mandatory = $true)][string]$CleanupDir
)

$ErrorActionPreference = 'Continue'
$log = Join-Path $env:TEMP 'vysh_update.log'
function Log($m) {
  try { "$(Get-Date -Format o)  $m" | Out-File -FilePath $log -Append -Encoding utf8 } catch {}
}
Log "=== update start: source=$SourceDir target=$TargetDir exe=$ExePath pid=$AppPid"

# 1) дождаться выхода приложения (до 120 с) и ещё немного, чтобы ОС
#    отпустила дескрипторы .exe / .dll.
for ($i = 0; $i -lt 120; $i++) {
  if (-not (Get-Process -Id $AppPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Seconds 1
}
Start-Sleep -Seconds 3

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
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
      '-File', $PSCommandPath,
      '-SourceDir', $SourceDir, '-TargetDir', $TargetDir, '-ExePath', $ExePath,
      '-AppPid', $AppPid, '-CleanupDir', $CleanupDir)
    exit 0
  } catch {
    Log "elevation failed: $_"
  }
}

# 3) скопировать новые файлы с повторами (защита от sharing violations).
#    /IS /IT /IM перезаписывают и файлы со старыми датами из архива.
$copied = $false
for ($attempt = 1; $attempt -le 8; $attempt++) {
  $null = & robocopy $SourceDir $TargetDir /E /IS /IT /IM /R:5 /W:3 /NFL /NDL /NJH /NJS /NP 2>&1
  $code = $LASTEXITCODE
  Log "robocopy attempt $attempt exit=$code"
  if ($code -lt 8) { $copied = $true; break }
  Start-Sleep -Seconds 2
}
if (-not $copied) { Log "update copy FAILED after retries" }

# 4) перезапустить приложение; рабочая папка - папка установки,
#    чтобы exe нашёл свои DLL.
try {
  Start-Process -FilePath $ExePath -WorkingDirectory $TargetDir
  Log "relaunched $ExePath"
} catch {
  Log "relaunch failed: $_"
}

Start-Sleep -Seconds 2
Remove-Item -LiteralPath $CleanupDir -Recurse -Force -ErrorAction SilentlyContinue
''';
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
      throw const UpdateInstallException(UpdateInstallError.wrongPlatform, 'Linux');
    }

    final appDir = File(Platform.resolvedExecutable).parent.path;
    final staging = await Directory.systemTemp.createTemp('vysh-update-');
    try {
      final result = await Process.run(
        'tar',
        ['-xzf', archive, '-C', staging.path],
      );
      if (result.exitCode != 0) {
        final tail = _tail(result.stderr);
        throw UpdateInstallException(
          tail != null ? UpdateInstallError.badArchive : UpdateInstallError.badArchive, tail
        );
      }

      final payload = findPayloadRoot(staging);
      if (payload == null) {
        throw const UpdateInstallException(UpdateInstallError.badArchive, 'vysh');
      }

      await _launchAfterExit(
        _portableScript,
        [payload, appDir, staging.path, archive],
      );
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

  static String? _tail(Object? stderr) {
    final lines = '$stderr'
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    return lines.skip(lines.length > 3 ? lines.length - 3 : 0).join('\n');
  }

  static const _portableScript = r'''
SRC="$1"; DST="$2"; STAGING="$3"; ARCHIVE="$4"
log "=== portable update: $SRC -> $DST"
if cp -a --remove-destination "$SRC/." "$DST/" 2>>"$LOG"; then
  log "copied"
else
  log "copy FAILED"
fi
rm -rf "$STAGING" "$ARCHIVE" 2>/dev/null
setsid "$DST/vysh" >/dev/null 2>&1 < /dev/null &
''';

  /// setsid уводит процесс из нашей группы, чтобы exit(0) его не прихватил.
  static Future<void> _launchAfterExit(
    String body,
    List<String> args,
  ) async {
    final script = File(
      '${Directory.systemTemp.path}/vysh_update_'
      '${DateTime.now().millisecondsSinceEpoch}.sh',
    );
    await script.writeAsString('$_waitForApp\n$body');
    final shArgs = [script.path, '$pid', ...args];
    try {
      await Process.start('setsid', ['sh', ...shArgs],
          mode: ProcessStartMode.detached);
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
    final result = await Process.run(
      'hdiutil',
      ['attach', '-noverify', '-noautoopen', dmgPath],
    );
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
    final mountPoint = _mountPointOf(result.stdout as String);
    if (mountPoint != null) {
      await Process.start(
        'open',
        [mountPoint],
        mode: ProcessStartMode.detached,
      );
    }
  }

  /// stdout hdiutil: таблица смонтированных разделов, точка монтирования -
  /// последняя колонка последней строки вида:
  /// `/dev/disk4s1  Apple_HFS  /Volumes/vysh`.
  static String? _mountPointOf(String stdout) {
    final lines = stdout
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    for (final line in lines.reversed) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length >= 3 && parts.last.startsWith('/Volumes/')) {
        return parts.last;
      }
    }
    return null;
  }
}
