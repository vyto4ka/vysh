import 'dart:async';
import 'dart:io';

import '../../infra/platform/local_files.dart';
import '../ports/sftp.dart';
import 'terminal_session.dart';
import 'transfer_queue.dart';

/// Высокоуровневые SFTP-действия вкладки: загрузка файлов и папок,
/// скачивание, «открыть локально» с автозагрузкой изменений.
class SftpActions {
  SftpActions({
    required this.tabId,
    required this.session,
    required this.queue,
    required this.downloadsDir,
  });

  final String tabId;
  final TerminalSession session;
  final TransferQueue queue;
  final String downloadsDir;

  Future<SftpSession> get _sftp => session.sftp();

  // ─── Загрузка на сервер ───────────────────────────────────────────

  /// Загрузить локальные файлы и папки (рекурсивно) в [remoteDir].
  Future<void> uploadPaths(List<String> localPaths, String remoteDir,
      {void Function()? onAllQueued, void Function()? onFileDone}) async {
    final sftp = await _sftp;
    for (final path in localPaths) {
      final type = await FileSystemEntity.type(path);
      final name = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;
      if (type == FileSystemEntityType.directory) {
        await _uploadDir(sftp, Directory(path), remoteJoin(remoteDir, name), onFileDone);
      } else if (type == FileSystemEntityType.file) {
        _enqueueUpload(sftp, File(path), remoteJoin(remoteDir, name), onFileDone);
      }
    }
    onAllQueued?.call();
  }

  Future<void> _uploadDir(
      SftpSession sftp, Directory dir, String remote, void Function()? onFileDone) async {
    await _mkdirIfMissing(sftp, remote);
    await for (final e in dir.list(followLinks: false)) {
      final name = e.path.split(RegExp(r'[\\/]')).last;
      if (e is Directory) {
        await _uploadDir(sftp, e, remoteJoin(remote, name), onFileDone);
      } else if (e is File) {
        _enqueueUpload(sftp, e, remoteJoin(remote, name), onFileDone);
      }
    }
  }

  Future<void> _mkdirIfMissing(SftpSession sftp, String path) async {
    try {
      final e = await sftp.stat(path);
      if (!e.isDir) throw SftpFailure('$path существует и это не папка');
    } on SftpFailure catch (e) {
      if (e.message.contains('не папка')) rethrow;
      await sftp.mkdir(path);
    }
  }

  String _enqueueUpload(SftpSession sftp, File file, String remote, void Function()? onDone) {
    final size = file.existsSync() ? file.lengthSync() : 0;
    return queue.enqueue(
      tabId: tabId,
      direction: TransferDirection.upload,
      name: remoteBasename(remote),
      localPath: file.path,
      remotePath: remote,
      total: size,
      run: (cancel, progress) =>
          sftp.upload(file, remote, cancel: cancel, onProgress: progress),
      onDone: onDone,
    );
  }

  // ─── Скачивание ──────────────────────────────────────────────────

  /// Скачать файлы и папки (рекурсивно) в папку загрузок.
  /// Возвращает локальный путь первого элемента (для «показать в папке»).
  Future<String?> download(List<RemoteEntry> entries, {String? targetDir}) async {
    final sftp = await _sftp;
    final dir = targetDir ?? downloadsDir;
    await Directory(dir).create(recursive: true);
    String? first;
    for (final e in entries) {
      final local = LocalFiles.uniquePath(dir, e.name);
      first ??= local;
      if (e.isDir) {
        await _downloadDir(sftp, e.path, Directory(local));
      } else {
        _enqueueDownload(sftp, e, File(local));
      }
    }
    return first;
  }

  Future<void> _downloadDir(SftpSession sftp, String remote, Directory local) async {
    await local.create(recursive: true);
    for (final e in await sftp.list(remote)) {
      final target = LocalFiles.join(local.path, e.name);
      if (e.isDir && !e.isLink) {
        await _downloadDir(sftp, e.path, Directory(target));
      } else if (!e.isDir) {
        _enqueueDownload(sftp, e, File(target));
      }
    }
  }

  String _enqueueDownload(SftpSession sftp, RemoteEntry e, File local, {void Function()? onDone}) {
    return queue.enqueue(
      tabId: tabId,
      direction: TransferDirection.download,
      name: e.name,
      localPath: local.path,
      remotePath: e.path,
      total: e.size,
      run: (cancel, progress) async {
        try {
          await sftp.download(e.path, local, cancel: cancel, onProgress: progress);
        } catch (_) {
          // Недокачанный файл не оставляем.
          try {
            if (await local.exists()) await local.delete();
          } catch (_) {}
          rethrow;
        }
      },
      onDone: onDone,
    );
  }

  // ─── Открыть локально ────────────────────────────────────────────

  /// Скачать во временную папку, открыть программой по умолчанию и
  /// заливать обратно при каждом сохранении. [onUploaded] - уведомление.
  Future<void> openLocally(RemoteEntry e, {required void Function(String name) onUploaded}) async {
    final sftp = await _sftp;
    final dir = await LocalFiles.editTempDir();
    final local = File(LocalFiles.join(dir.path, e.name));

    _enqueueDownload(sftp, e, local, onDone: () async {
      await LocalFiles.openWithSystem(local.path);
      var lastModified = await local.lastModified();
      Timer? debounce;
      final sub = dir.watch().listen((event) {
        if (!event.path.endsWith(e.name)) return;
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 700), () async {
          if (!await local.exists()) return;
          final m = await local.lastModified();
          if (!m.isAfter(lastModified)) return;
          lastModified = m;
          try {
            final s = await _sftp;
            _enqueueUpload(s, local, e.path, () => onUploaded(e.name));
          } catch (_) {}
        });
      });
      session.editWatchers.add(sub);
    });
  }
}
