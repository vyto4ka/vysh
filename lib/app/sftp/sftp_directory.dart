import 'package:flutter/foundation.dart';

import '../../domain/ports/sftp.dart';
import '../settings/app_settings.dart';

/// Отсортировать список записей: папки всегда первыми, внутри групп — по [field].
List<RemoteEntry> sortSftpEntries(
  Iterable<RemoteEntry> source,
  SftpSortField field, {
  bool ascending = true,
}) {
  final list = [...source];
  final dirSign = ascending ? 1 : -1;
  String extOf(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 && dot < name.length - 1
        ? name.substring(dot + 1).toLowerCase()
        : '';
  }

  list.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    int cmp = switch (field) {
      SftpSortField.name => a.name.toLowerCase().compareTo(
        b.name.toLowerCase(),
      ),
      SftpSortField.size => a.isDir ? 0 : a.size.compareTo(b.size),
      SftpSortField.modified =>
        (a.modified ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
          b.modified ?? DateTime.fromMillisecondsSinceEpoch(0),
        ),
      SftpSortField.type =>
        a.isDir ? 0 : extOf(a.name).compareTo(extOf(b.name)),
    };
    if (cmp == 0) {
      cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
    return cmp * dirSign;
  });
  return list;
}

/// Разбить путь на кликабельные сегменты для хлебных крошек.
List<({String label, String path})> sftpBreadcrumbs(
  String path, {
  required bool windows,
}) {
  if (!windows) {
    final clean = path.isEmpty ? '/' : path;
    final parts = clean.split('/').where((s) => s.isNotEmpty).toList();
    final out = <({String label, String path})>[(label: '/', path: '/')];
    var accum = '';
    for (final p in parts) {
      accum = '$accum/$p';
      out.add((label: p, path: accum));
    }
    return out;
  }

  final norm = path.replaceAll('/', r'\').trim();
  final out = <({String label, String path})>[(label: r'\', path: r'\')];
  if (norm.isEmpty || norm == r'\') return out;
  if (norm.startsWith(r'\\')) {
    final parts = norm
        .substring(2)
        .split(r'\')
        .where((s) => s.isNotEmpty)
        .toList();
    var accum = r'\';
    for (var i = 0; i < parts.length; i++) {
      accum = i == 0 ? '\\\\${parts[i]}' : '$accum\\${parts[i]}';
      out.add((label: parts[i], path: accum));
    }
    return out;
  }
  final parts = norm.split(r'\').where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return out;
  final drive = parts.first.endsWith(':') ? '${parts.first}\\' : parts.first;
  out.add((label: drive, path: drive));
  var accum = drive.endsWith(r'\')
      ? drive.substring(0, drive.length - 1)
      : drive;
  for (final p in parts.skip(1)) {
    accum = '$accum\\$p';
    out.add((label: p, path: accum));
  }
  return out;
}

/// Стек истории переходов Назад / Вперёд одной панели проводника.
class SftpPathHistory {
  final _entries = <String>[];
  int _index = -1;

  bool get canBack => _index > 0;
  bool get canForward => _index >= 0 && _index < _entries.length - 1;
  String? get current => _index >= 0 ? _entries[_index] : null;

  void record(String path) {
    if (_index >= 0 && _entries[_index] == path) return;
    if (_index < _entries.length - 1) {
      _entries.removeRange(_index + 1, _entries.length);
    }
    _entries.add(path);
    if (_entries.length > 64) {
      _entries.removeAt(0);
    } else {
      _index++;
    }
  }

  String? back() {
    if (!canBack) return null;
    return _entries[--_index];
  }

  String? forward() {
    if (!canForward) return null;
    return _entries[++_index];
  }

  void clear() {
    _entries.clear();
    _index = -1;
  }
}

/// Содержимое одной удалённой папки для панели файлов: текущий путь,
/// список, загрузка и ошибка. Применяется только ответ на последний запрос:
/// если открыть папку A, затем B, а ответ A придёт позже, экран останется на B.
class SftpDirectory extends ChangeNotifier {
  SftpDirectory(this._sftp, {this.resetChannel});

  final Future<SftpSession> Function() _sftp;

  /// Сбросить SFTP-канал перед повторной попыткой после ошибки.
  final void Function()? resetChannel;

  /// Открытая папка; null - ещё ни одна не открыта.
  String? get cwd => _cwd;
  String? _cwd;

  /// Папки сначала, по имени без учёта регистра.
  List<RemoteEntry> get entries => _entries;
  List<RemoteEntry> _entries = const [];

  bool get loading => _loading;
  bool _loading = false;

  /// Ошибка последнего запроса (SftpFailure и т. п.); текст собирает UI.
  Object? get error => _error;
  Object? _error;

  /// Путь последнего запроса - чтобы показать его в поле при ошибке.
  String? get requestedPath => _requested;
  String? _requested;

  int _request = 0;
  bool _disposed = false;

  bool _stale(int request) => _disposed || request != _request;

  void _set(void Function() change) {
    if (_disposed) return;
    change();
    notifyListeners();
  }

  /// Открыть домашнюю папку (после ошибки - через новый SFTP-канал).
  Future<void> home() async {
    if (_error != null) resetChannel?.call();
    final request = ++_request;
    _set(() {
      _loading = true;
      _error = null;
    });
    try {
      final path = await (await _sftp()).home();
      if (_stale(request)) return;
      await open(path);
    } catch (e) {
      if (_stale(request)) return;
      _set(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> open(String path) async {
    final request = ++_request;
    _set(() {
      _loading = true;
      _error = null;
      _requested = path;
    });
    try {
      // Копия: порт не обещает изменяемый список.
      final list = sortSftpEntries(
        await (await _sftp()).list(path),
        SftpSortField.name,
      );
      if (_stale(request)) return;
      _set(() {
        _cwd = path;
        _entries = list;
        _loading = false;
      });
    } catch (e) {
      if (_stale(request)) return;
      _set(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> refresh() async {
    final cwd = _cwd;
    if (cwd != null) await open(cwd);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
