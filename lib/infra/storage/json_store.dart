import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';

/// Простое хранилище одного JSON-файла в папке конфигурации.
///
/// Чтение синхронное (на старте, файлы маленькие), запись - асинхронная,
/// последовательная и атомарная (через временный файл + rename).
class JsonStore {
  JsonStore(this.fileName);

  final String fileName;
  Future<void> _queue = Future.value();

  File get file => AppPaths.file(fileName);

  Object? readSync() {
    try {
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync();
      if (text.trim().isEmpty) return null;
      return jsonDecode(text);
    } catch (_) {
      // Битый файл не должен ронять приложение.
      return null;
    }
  }

  Future<void> write(Object? data) {
    final text = const JsonEncoder.withIndent('  ').convert(data);
    _queue = _queue.then((_) async {
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    }).catchError((_) {});
    return _queue;
  }
}
