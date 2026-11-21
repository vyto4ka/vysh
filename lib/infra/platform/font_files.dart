import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/services/font_info.dart';
import '../storage/app_paths.dart';
import 'memory_trimmer.dart';

export '../../domain/services/font_info.dart' show AddFontError, AddFontException;

/// Шрифт, добавленный пользователем: файл в папке профиля `fonts/`.
class UserFont {
  const UserFont({required this.fileName, required this.family, required this.monospace});

  /// Имя файла в `fonts/` - по нему шрифт хранится в настройках.
  final String fileName;

  /// Имя семейства из самого файла (для списка).
  final String family;

  final bool monospace;

  /// Под этим именем файл зарегистрирован во Flutter. Своё пространство
  /// имён: системный шрифт с тем же названием не перепутается с файлом.
  String get loadedFamily => familyFor(fileName);

  static String familyFor(String fileName) => 'vysh-file:$fileName';
}

/// Шрифты: системные моноширинные и свои файлы в профиле.
abstract final class FontFiles {
  /// Больше - почти наверняка не терминальный шрифт (полный CJK-набор
  /// весит 15-20 МБ, Nerd Font около 2,5 МБ).
  static const maxFileBytes = 32 << 20;

  static const extensions = ['ttf', 'otf'];

  static Directory get userDir => Directory('${AppPaths.configDir.path}${Platform.pathSeparator}fonts');

  // ── Системные ──

  /// Моноширинные семейства, установленные в системе, по алфавиту.
  /// Разбор файлов идёт в отдельном изоляте и не тормозит интерфейс.
  /// Android и web - пустой список: системного набора по сути нет.
  static Future<List<String>> systemMonospace() async {
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) return const [];
    final files = await _systemFontFiles();
    final families = await Isolate.run(() => monospaceFamilies(files));
    MemoryTrimmer.trimProcessMemory();
    return families;
  }

  /// Семейства из [paths], у которых буквы одной ширины. Без повторов,
  /// по алфавиту без учёта регистра.
  static List<String> monospaceFamilies(Iterable<String> paths) {
    final byKey = <String, String>{};
    for (final path in paths) {
      for (final info in readInfo(path)) {
        if (!info.monospace) continue;
        byKey.putIfAbsent(info.family.toLowerCase(), () => info.family);
      }
    }
    return byKey.values.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }

  /// Сведения о шрифте в файле; не шрифт или нет доступа - пустой список.
  static List<FontInfo> readInfo(String path) {
    RandomAccessFile? f;
    try {
      f = File(path).openSync();
      final file = f;
      final size = file.lengthSync();
      return FontInfoParser.parse((offset, length) {
        if (offset < 0 || offset >= size || length <= 0) return Uint8List(0);
        file.setPositionSync(offset);
        return file.readSync(length);
      });
    } catch (_) {
      return const [];
    } finally {
      try {
        f?.closeSync();
      } catch (_) {}
    }
  }

  static Future<List<String>> _systemFontFiles() async {
    // Linux: у fontconfig полный список, включая Nix, Flatpak и свои папки.
    if (Platform.isLinux) {
      try {
        final r = await Process.run('fc-list', ['--format', r'%{file}\n']);
        if (r.exitCode == 0) {
          final list = '${r.stdout}'
              .split('\n')
              .map((l) => l.trim())
              .where(_isFontFile)
              .toSet()
              .toList();
          if (list.isNotEmpty) return list;
        }
      } catch (_) {}
    }
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
    final dirs = <String>[
      if (Platform.isWindows) ...[
        '${env['WINDIR'] ?? r'C:\Windows'}\\Fonts',
        if (env['LOCALAPPDATA'] != null) '${env['LOCALAPPDATA']}\\Microsoft\\Windows\\Fonts',
      ],
      if (Platform.isMacOS) ...[
        '/System/Library/Fonts',
        '/Library/Fonts',
        '$home/Library/Fonts',
      ],
      if (Platform.isLinux) ...[
        '/usr/share/fonts',
        '/usr/local/share/fonts',
        '$home/.local/share/fonts',
        '$home/.fonts',
      ],
    ];
    final result = <String>[];
    for (final d in dirs) {
      try {
        final dir = Directory(d);
        if (!dir.existsSync()) continue;
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is File && _isFontFile(e.path)) result.add(e.path);
        }
      } catch (_) {}
    }
    return result;
  }

  static bool _isFontFile(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.ttf') || p.endsWith('.otf') || p.endsWith('.ttc') || p.endsWith('.otc');
  }

  // ── Свои файлы ──

  static final _loaded = <String>{};

  /// Шрифты из `fonts/` профиля. Файлы, которые не разобрались, пропускаются.
  static List<UserFont> listUser() {
    try {
      final dir = userDir;
      if (!dir.existsSync()) return const [];
      final fonts = <UserFont>[];
      for (final e in dir.listSync()) {
        if (e is! File) continue;
        final name = _baseName(e.path);
        final ext = name.contains('.') ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : '';
        if (!extensions.contains(ext)) continue;
        final info = readInfo(e.path);
        if (info.isEmpty) continue;
        fonts.add(UserFont(fileName: name, family: info.first.family, monospace: info.first.monospace));
      }
      fonts.sort((a, b) => a.family.toLowerCase().compareTo(b.family.toLowerCase()));
      return fonts;
    } catch (_) {
      return const [];
    }
  }

  /// Копирует файл шрифта в профиль. Бросает [AddFontException].
  static Future<UserFont> addUser(String sourcePath) async {
    final src = File(sourcePath);
    final int size;
    try {
      size = await src.length();
    } catch (e) {
      throw AddFontException(AddFontError.copyFailed, '$e');
    }
    if (size > maxFileBytes) throw const AddFontException(AddFontError.tooLarge);

    final info = readInfo(sourcePath);
    if (info.isEmpty) throw const AddFontException(AddFontError.notFont);

    final original = _baseName(sourcePath);
    final dot = original.lastIndexOf('.');
    final ext = dot > 0 ? original.substring(dot + 1).toLowerCase() : '';
    if (!extensions.contains(ext)) throw const AddFontException(AddFontError.notFont);
    final stem = _safeStem(dot > 0 ? original.substring(0, dot) : original);

    try {
      final dir = userDir;
      await dir.create(recursive: true);
      var name = '$stem.$ext';
      for (var i = 2; File('${dir.path}${Platform.pathSeparator}$name').existsSync(); i++) {
        name = '$stem-$i.$ext';
      }
      final target = '${dir.path}${Platform.pathSeparator}$name';
      final tmp = File('$target.part');
      await src.copy(tmp.path);
      await tmp.rename(target);
      final font = UserFont(fileName: name, family: info.first.family, monospace: info.first.monospace);
      await load(font);
      return font;
    } on AddFontException {
      rethrow;
    } catch (e) {
      throw AddFontException(AddFontError.copyFailed, '$e');
    }
  }

  static Future<void> deleteUser(String fileName) async {
    try {
      await File('${userDir.path}${Platform.pathSeparator}${_baseName(fileName)}').delete();
    } catch (_) {}
  }

  /// Регистрирует шрифт во Flutter. Уже загруженный второй раз не читается.
  /// Если в файле только обычное начертание, жирное Flutter нарисует сам.
  static Future<bool> load(UserFont font) async {
    if (_loaded.contains(font.fileName)) return true;
    try {
      final bytes = await File('${userDir.path}${Platform.pathSeparator}${font.fileName}').readAsBytes();
      final loader = FontLoader(font.loadedFamily)..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
      _loaded.add(font.fileName);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Загрузить шрифт по имени файла (выбранный в настройках) до первого кадра.
  static Future<void> loadByFileName(String fileName) async {
    for (final f in listUser()) {
      if (f.fileName == fileName) {
        await load(f);
        return;
      }
    }
  }

  static String _baseName(String path) {
    final i = path.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? path : path.substring(i + 1);
  }

  static String _safeStem(String stem) {
    final s = stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').replaceAll(RegExp(r'^[._]+'), '');
    if (s.isEmpty) return 'font';
    return s.length > 64 ? s.substring(0, 64) : s;
  }
}
