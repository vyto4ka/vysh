import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/models/local_file_failure.dart';

/// Работа с локальными файлами и системными приложениями.
class LocalFiles {
  LocalFiles._();

  static String get _home {
    if (kIsWeb) return '/Downloads';
    try {
      final env = Platform.environment;
      return env['HOME'] ?? env['USERPROFILE'] ?? Directory.current.path;
    } catch (_) {
      return '/Downloads';
    }
  }

  static String join(String a, String b) {
    if (kIsWeb) return '$a/$b';
    try {
      return a.endsWith(Platform.pathSeparator) ? '$a$b' : '$a${Platform.pathSeparator}$b';
    } catch (_) {
      return '$a/$b';
    }
  }

  // ─── Общая папка Download на Android ────────────────────────────

  static const _filesChannel = MethodChannel('uwu.vyto4ka.vysh/local_files');

  /// Публичная Download: файл качается во временную папку и публикуется
  /// через MediaStore.Downloads (Android 10+) или копируется напрямую
  /// (Android 9-, с запросом разрешения). [subDir] - путь внутри Download,
  /// чтобы скачанная папка сохранила структуру.
  /// Возвращает URI опубликованного файла; при неудаче бросает исключение.
  static Future<String> saveToDownloads(String tempPath, String name,
      {String subDir = '', String? mimeType}) async {
    try {
      final uri = await _filesChannel.invokeMethod<String>('saveToDownloads', {
        'tempPath': tempPath,
        'name': name,
        'subDir': subDir,
        'mimeType': mimeType,
      });
      if (uri == null) throw const LocalFileFailure(LocalFileError.publishFailed);
      return uri;
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        throw const LocalFileFailure(LocalFileError.storagePermissionDenied);
      }
      throw LocalFileFailure(LocalFileError.publishFailed, {'detail': e.message ?? e.code});
    }
  }

  /// Системный диалог «Сохранить как» (Android, SAF ACTION_CREATE_DOCUMENT):
  /// пользователь выбирает место и имя файла, байты [bytes] записываются туда.
  /// Возвращает URI сохранённого файла; null - пользователь отменил диалог.
  /// На других платформах/неудаче бросает исключение или возвращает null.
  static Future<String?> saveDocument(
      List<int> bytes, String suggestedName, String mimeType) async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      return await _filesChannel.invokeMethod<String>('saveDocument', {
        'bytes': Uint8List.fromList(bytes),
        'suggestedName': suggestedName,
        'mimeType': mimeType,
      });
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION_DENIED') {
        throw const LocalFileFailure(LocalFileError.storagePermissionDenied);
      }
      throw LocalFileFailure(LocalFileError.publishFailed, {'detail': e.message ?? e.code});
    }
  }

  /// Отправить текст через системное меню «Поделиться» (Android).
  /// false - платформа так не умеет или отправка не удалась.
  static Future<bool> shareText(String text) async {
    if (kIsWeb || !Platform.isAndroid) return false;
    try {
      return await _filesChannel.invokeMethod<bool>('shareText', {'text': text}) ?? false;
    } catch (_) {
      return false;
    }
  }

  // ─── Безопасные локальные имена ─────────────────────────────────

  static const _windowsReserved = {
    'CON', 'PRN', 'AUX', 'NUL', //
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
  };

  /// Имя файла с сервера → имя, которое можно безопасно создать локально.
  ///
  /// Имя приходит от сервера и не должно выводить за выбранную папку:
  /// на Linux `\` - обычный символ имени, а Windows считает его разделителем,
  /// так что `..\x` указывало бы в родительскую папку. Убираем разделители
  /// обеих систем, `.`/`..`, недопустимые в Windows символы (в том числе `:` -
  /// альтернативные потоки NTFS), управляющие символы и имена устройств.
  static String safeName(String remoteName) {
    var name = remoteName.replaceAll(RegExp(r'[\x00-\x1f\x7f/\\]'), '_');
    final windows = !kIsWeb && Platform.isWindows;
    if (windows) {
      name = name.replaceAll(RegExp(r'[<>:"|?*]'), '_');
      // Windows молча отбрасывает точки и пробелы в конце имени.
      name = name.replaceAll(RegExp(r'[. ]+$'), '');
      final stem = name.split('.').first.trim().toUpperCase();
      if (_windowsReserved.contains(stem)) name = '_$name';
    }
    if (name.isEmpty || name == '.' || name == '..') name = '_';
    return name;
  }

  /// Лежит ли [path] внутри [root] (после нормализации `.`/`..`).
  static bool isWithin(String root, String path) {
    if (kIsWeb) return true;
    String norm(String p) {
      final abs = File(p).absolute.path;
      final parts = <String>[];
      for (final s in abs.split(RegExp(r'[\\/]'))) {
        if (s.isEmpty || s == '.') continue;
        if (s == '..') {
          if (parts.isNotEmpty) parts.removeLast();
        } else {
          parts.add(Platform.isWindows ? s.toLowerCase() : s);
        }
      }
      return parts.join('/');
    }

    final r = norm(root);
    final p = norm(path);
    return p.startsWith('$r/');
  }

  /// [dir]/[name] с проверкой, что результат не выходит за [dir].
  static String childPath(String dir, String name) {
    final path = join(dir, name);
    if (!isWithin(dir, path)) {
      throw LocalFileFailure(LocalFileError.badRemoteName, {'name': name});
    }
    return path;
  }

  /// На Android качаем во временную папку (файл потом уходит в Download),
  /// на остальных - сразу в «Загрузки».
  static String defaultDownloadsDir() {
    if (kIsWeb) return 'Downloads';
    try {
      if (Platform.isAndroid) {
        return Directory.systemTemp.path;
      }
      if (Platform.isLinux) {
        // XDG_DOWNLOAD_DIR из ~/.config/user-dirs.dirs (бывает «Загрузки»).
        try {
          final f = File(join(_home, '.config/user-dirs.dirs'));
          if (f.existsSync()) {
            final m = RegExp(r'^XDG_DOWNLOAD_DIR="(.+)"', multiLine: true)
                .firstMatch(f.readAsStringSync());
            if (m != null) return m.group(1)!.replaceAll(r'$HOME', _home);
          }
        } catch (_) {}
      }
      return join(_home, 'Downloads');
    } catch (_) {
      return 'Downloads';
    }
  }

  /// Пути, уже отданные передачам в очереди, но ещё не созданные на диске.
  static final _reserved = <String>{};

  static String _key(String path) =>
      !kIsWeb && Platform.isWindows ? path.toLowerCase() : path;

  static bool _taken(String path) =>
      _reserved.contains(_key(path)) ||
      FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.notFound;

  /// Свободный путь в [dir] для имени с сервера: file.txt → file (1).txt,
  /// если такой файл/папка уже есть или занят другой передачей. Путь
  /// резервируется до [releasePath] - две параллельные загрузки одного
  /// имени не получат один и тот же файл.
  static String uniquePath(String dir, String remoteName) {
    final name = safeName(remoteName);
    if (kIsWeb) return join(dir, name);
    var candidate = childPath(dir, name);
    if (_taken(candidate)) {
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      for (var i = 1;; i++) {
        candidate = childPath(dir, '$base ($i)$ext');
        if (!_taken(candidate)) break;
      }
    }
    _reserved.add(_key(candidate));
    return candidate;
  }

  /// Снять резерв с пути (передача закончилась или не началась).
  static void releasePath(String path) => _reserved.remove(_key(path));

  /// Временная папка для открытия файлов во внешнем редакторе.
  /// Заодно убирает такие папки старше суток: сразу после закрытия вкладки
  /// их не удаляем, чтобы не отобрать файл у ещё открытого редактора.
  static Future<Directory> editTempDir() => _tempDir('vysh-edit-');

  /// Временная папка для файлов, которые перетаскивают из панели SFTP в
  /// файловый менеджер: туда скачивается копия, оттуда её забирает получатель.
  static Future<Directory> dragTempDir() => _tempDir('vysh-drag-');

  static Future<Directory> _tempDir(String prefix) async {
    final base = Directory.systemTemp;
    try {
      final old = DateTime.now().subtract(const Duration(days: 1));
      await for (final e in base.list(followLinks: false)) {
        if (e is! Directory || !e.path.split(RegExp(r'[\\/]')).last.startsWith(prefix)) {
          continue;
        }
        try {
          if ((await e.stat()).modified.isBefore(old)) await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    return base.createTemp(prefix);
  }

  /// Расширения, которые Windows по двойному клику запускает, а не открывает.
  static final windowsRunnable = RegExp(
    r'\.(exe|com|bat|cmd|ps1|psm1|vbs|vbe|js|jse|wsf|wsh|hta|msi|msp|scr|pif|cpl|lnk|url|reg|jar|msc|scf|appref-ms|application)$',
    caseSensitive: false,
  );

  /// Открыть файл программой по умолчанию. Бросает исключение при ошибке.
  ///
  /// Windows: не через `cmd /c start` - cmd разбирает строку сам, и имя файла
  /// с сервера вроде `a&calc` выполнило бы команду. PowerShell получает путь
  /// через переменную окружения и не разбирает его как код.
  static Future<void> openWithSystem(String path) async {
    if (kIsWeb) return;
    if (Platform.isWindows) {
      final url = RegExp(r'^https?://', caseSensitive: false).hasMatch(path);
      // «Открыть» такой файл значит запустить его - скрипт с сервера
      // выполнился бы здесь. Показываем текст.
      if (!url && windowsRunnable.hasMatch(path)) {
        await Process.start('notepad.exe', [path], mode: ProcessStartMode.detached);
        return;
      }
      // Файл - Invoke-Item -LiteralPath (без разбора `[`/`*` как шаблона),
      // ссылку - Start-Process.
      final r = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          url
              ? r'Start-Process -FilePath $env:VYSH_OPEN_PATH'
              : r'Invoke-Item -LiteralPath $env:VYSH_OPEN_PATH',
        ],
        environment: {'VYSH_OPEN_PATH': path},
      );
      if (r.exitCode != 0) {
        throw LocalFileFailure(LocalFileError.openFailed, {'detail': '${r.stderr}'.trim()});
      }
    } else if (Platform.isMacOS) {
      await Process.start('open', [path], mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
    }
  }

  /// Открыть ссылку https в браузере или системном приложении.
  /// На Android openWithSystem не работает (процессов нет) - ACTION_VIEW.
  static Future<void> openUrl(String url) async {
    if (kIsWeb) return;
    if (Platform.isAndroid) {
      await _filesChannel.invokeMethod('openUrl', {'url': url});
      return;
    }
    await openWithSystem(url);
  }

  /// Запустить системный установщик APK (Android): показывается диалог
  /// «Обновить это приложение?». [path] - скачанный .apk.
  static Future<void> installApk(String path) async {
    if (kIsWeb || !Platform.isAndroid) return;
    await _filesChannel.invokeMethod('installApk', {'path': path});
  }

  /// Показать файл/папку в файловом менеджере.
  static Future<void> reveal(String path) async {
    if (kIsWeb) return;
    try {
      if (Platform.isWindows) {
        final isDir = Directory(path).existsSync();
        await Process.start('explorer', isDir ? [path] : ['/select,$path'],
            mode: ProcessStartMode.detached);
      } else if (Platform.isAndroid) {
        // Файловый менеджер открываем через платформенный канал:
        // Process.start на Android не работает.
        await _filesChannel.invokeMethod('revealPath', {'path': path});
      } else if (Platform.isLinux || Platform.isMacOS) {
        final target = Directory(path).existsSync() ? path : File(path).parent.path;
        await openWithSystem(target);
      }
    } catch (_) {}
  }
}
