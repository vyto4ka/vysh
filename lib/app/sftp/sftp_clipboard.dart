import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/ports/sftp.dart';

/// Внутренний буфер обмена файлами и папками (Копировать / Вырезать / Вставить)
/// внутри одного сервера, локальной системы или между разными вкладками.
class SftpClipboardData {
  const SftpClipboardData({
    required this.sourceIdentity,
    required this.openSource,
    required this.entries,
    required this.cut,
  });

  /// Идентификатор файловой системы источника (`local` или `user@host:port`).
  final String sourceIdentity;

  /// Открыть сессию источника для чтения/удаления при вставке.
  final Future<SftpSession> Function() openSource;

  /// Выбранные записи на момент копирования или вырезания.
  final List<RemoteEntry> entries;

  /// true — перемещение (`Ctrl+X`), false — копирование (`Ctrl+C`).
  final bool cut;
}

class SftpClipboardController extends Notifier<SftpClipboardData?> {
  @override
  SftpClipboardData? build() => null;

  void setEntries({
    required String sourceIdentity,
    required Future<SftpSession> Function() openSource,
    required List<RemoteEntry> entries,
    required bool cut,
  }) {
    if (entries.isEmpty) return;
    state = SftpClipboardData(
      sourceIdentity: sourceIdentity,
      openSource: openSource,
      entries: List.unmodifiable(entries),
      cut: cut,
    );
  }

  void clear() => state = null;
}

final sftpClipboardProvider =
    NotifierProvider<SftpClipboardController, SftpClipboardData?>(
      SftpClipboardController.new,
    );

/// Безопасно экранировать путь для вставки в командную строку оболочки.
String shellQuotePath(String path, {required bool windows}) {
  if (windows) {
    final escaped = path.replaceAll('"', '""');
    return RegExp(r'[\s&|<>^()%!]').hasMatch(escaped) ? '"$escaped"' : escaped;
  }
  if (path.isNotEmpty && RegExp(r'^[A-Za-z0-9_./:@+-]+$').hasMatch(path)) {
    return path;
  }
  return "'${path.replaceAll("'", r"'\''")}'";
}

/// Команда перехода в папку для отправки в терминал.
String shellCdCommand(String path, {required bool windows}) {
  if (windows) {
    return 'cd /d "${path.replaceAll('"', '""')}"\r';
  }
  return 'cd -- ${shellQuotePath(path, windows: false)}\r';
}
