import 'dart:async';
import 'dart:io';

import '../../infra/platform/capabilities.dart';
import '../../infra/platform/local_files.dart';
import '../../l10n/app_strings.dart';
import '../../domain/ports/sftp.dart';
import '../terminal/terminal_session.dart';
import '../controllers/transfer_queue.dart';
import 'file_copy.dart';
import '../../infra/platform/local_file_session.dart';

/// Ответ на вопрос о файлах, которые уже есть на сервере:
/// true - заменить, false - пропустить их, null - отменить загрузку.
typedef ConfirmOverwrite = Future<bool?> Function(List<String> names);

/// Высокоуровневые SFTP-действия вкладки: загрузка файлов и папок,
/// скачивание, «открыть локально» с автозагрузкой изменений.
///
/// Методы возвращаются, когда задачи поставлены в очередь; результат самих
/// передач виден в очереди (и в колбэках onFileDone/onUploaded).
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
  /// Если файлы с такими именами уже есть, спрашивает [confirmOverwrite]
  /// Без обработчика конфликт отменяет копирование. Папки сливаются.
  Future<void> uploadPaths(
    List<String> localPaths,
    String remoteDir, {
    void Function()? onAllQueued,
    void Function()? onFileDone,
    ConfirmOverwrite? confirmOverwrite,
    ResolveCopyConflict? resolveConflict,
  }) async {
    final sftp = await _sftp;
    const local = LocalFileSession();
    final entries = [for (final path in localPaths) await local.stat(path)];
    queue.enqueue(
      tabId: tabId,
      direction: TransferDirection.upload,
      name: entries.map((e) => e.name).join(', '),
      localPath: localPaths.firstOrNull ?? '',
      remotePath: remoteDir,
      total: 0,
      run: (cancel, progress) async {
        final copy = FileCopy(
          source: local,
          target: sftp,
          cancel: cancel,
          progress: progress,
          resolve: (path) async {
            if (resolveConflict != null) return resolveConflict(path);
            final answer = await confirmOverwrite?.call([path]);
            return CopyDecision(
              answer == true
                  ? CopyChoice.replace
                  : answer == false
                  ? CopyChoice.skip
                  : CopyChoice.cancel,
            );
          },
        );
        for (final entry in entries) {
          await copy.copy(entry, copy.child(remoteDir, entry.name));
          onFileDone?.call();
        }
      },
    );
    onAllQueued?.call();
  }

  String _enqueueUpload(
    SftpSession sftp,
    File file,
    String remote,
    void Function()? onDone, {
    void Function()? onSettled,
  }) {
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
      onSettled: onSettled,
    );
  }

  // ─── Скачивание ──────────────────────────────────────────────────

  /// Скачать файлы и папки (рекурсивно) в папку загрузок.
  /// Возвращает локальный путь первого элемента (для «показать в папке»).
  Future<String?> download(
    List<RemoteEntry> entries, {
    String? targetDir,
    ResolveCopyConflict? resolveConflict,
  }) async {
    final sftp = await _sftp;
    var dir = targetDir ?? downloadsDir;
    // Целевая папка может быть недоступна (удалена, диск отвалился, путь
    // из настроек остался от другой машины) - тогда скачиваем в системную
    // «Загрузки». Если и она недоступна, ошибка всплывёт от передачи.
    try {
      await Directory(dir).create(recursive: true);
    } catch (_) {
      final fallback = LocalFiles.defaultDownloadsDir();
      if (fallback != dir) {
        await Directory(fallback).create(recursive: true);
        dir = fallback;
      } else {
        rethrow;
      }
    }
    if (resolveConflict != null &&
        !PlatformCapabilities.sharedDownloads &&
        entries.isNotEmpty) {
      const local = LocalFileSession();
      final destination = dir;
      queue.enqueue(
        tabId: tabId,
        direction: TransferDirection.download,
        name: entries.map((e) => e.name).join(', '),
        localPath: dir,
        remotePath: entries.first.path,
        total: 0,
        run: (cancel, progress) async {
          final copy = FileCopy(
            source: sftp,
            target: local,
            cancel: cancel,
            progress: progress,
            resolve: resolveConflict,
          );
          for (final e in entries) {
            await copy.copy(e, copy.child(destination, e.name));
          }
        },
      );
      return LocalFiles.childPath(dir, LocalFiles.safeName(entries.first.name));
    }
    String? first;
    for (final e in entries) {
      final local = LocalFiles.uniquePath(dir, e.name);
      first ??= local;
      if (e.isDir) {
        try {
          final folder = Directory(local);
          await _downloadDir(
            sftp,
            e.path,
            folder,
            subDir: folder.path.split(RegExp(r'[\\/]')).last,
          );
        } finally {
          LocalFiles.releasePath(local);
        }
      } else {
        _enqueueDownload(sftp, e, File(local), publishTo: '');
      }
    }
    return first;
  }

  Future<void> _downloadDir(
    SftpSession sftp,
    String remote,
    Directory local, {
    required String subDir,
  }) async {
    await local.create(recursive: true);
    for (final e in await sftp.list(remote)) {
      // Имена с сервера могут совпасть после очистки (`a:b` и `a_b` на
      // Windows) - поэтому тоже через uniquePath.
      final target = LocalFiles.uniquePath(local.path, e.name);
      final childName = target.split(RegExp(r'[\\/]')).last;
      if (e.isDir && !e.isLink) {
        try {
          await _downloadDir(
            sftp,
            e.path,
            Directory(target),
            subDir: '$subDir/$childName',
          );
        } finally {
          LocalFiles.releasePath(target);
        }
      } else if (!e.isDir) {
        _enqueueDownload(sftp, e, File(target), publishTo: subDir);
      } else {
        LocalFiles.releasePath(target);
      }
    }
  }

  /// [publishTo] - на Android файл после скачивания публикуется в общую
  /// Download (в эту подпапку); null - не публиковать (локальное редактирование).
  String _enqueueDownload(
    SftpSession sftp,
    RemoteEntry e,
    File local, {
    String? publishTo,
    FutureOr<void> Function()? onDone,
    void Function()? onSettled,
  }) {
    // Качаем во временный `.part` рядом: под окончательным именем файл
    // появляется только целым.
    final part = File('${local.path}.vysh-part');
    return queue.enqueue(
      tabId: tabId,
      direction: TransferDirection.download,
      name: e.name,
      localPath: local.path,
      remotePath: e.path,
      total: e.size,
      run: (cancel, progress) async {
        try {
          await sftp.download(
            e.path,
            part,
            cancel: cancel,
            onProgress: progress,
          );
          if (cancel.isCancelled) throw const TransferCancelled();
          await part.rename(local.path);
        } catch (_) {
          // Недокачанный файл не оставляем.
          try {
            if (await part.exists()) await part.delete();
          } catch (_) {}
          rethrow;
        }
        if (publishTo != null && PlatformCapabilities.sharedDownloads) {
          // На Android файл лежит во временной папке - переносим в общую
          // Download. Не получилось - это ошибка задачи, а не «готово».
          final published = await LocalFiles.saveToDownloads(
            local.path,
            local.path.split(RegExp(r'[\\/]')).last,
            subDir: publishTo,
          );
          queue.setPublished(tabId, local.path, published);
        }
      },
      onDone: onDone,
      onSettled: () {
        LocalFiles.releasePath(local.path);
        onSettled?.call();
      },
    );
  }

  // ─── Перетаскивание в файловый менеджер ──────────────────────────

  /// Скачать файл или папку во временную папку для перетаскивания.
  /// Передачи видны в очереди как обычные скачивания; [DragDownload.path]
  /// завершается, когда скачано всё, или ошибкой, если что-то не вышло.
  DragDownload downloadForDrag(RemoteEntry e) {
    final drag = DragDownload._(queue);
    drag.path = () async {
      final sftp = await _sftp;
      final dir = await LocalFiles.dragTempDir();
      final local = LocalFiles.childPath(dir.path, LocalFiles.safeName(e.name));
      final waits = <Future<void>>[];
      if (e.isDir) {
        await _dragDir(sftp, drag, e.path, Directory(local), waits);
      } else {
        waits.add(_dragFile(sftp, drag, e, File(local)));
      }
      await Future.wait(waits);
      if (drag._cancelled) throw const TransferCancelled();
      return local;
    }();
    // Ошибку забирает тот, кто ждёт path; без ожидания она не должна
    // всплыть необработанной.
    drag.path.ignore();
    return drag;
  }

  Future<void> _dragDir(
    SftpSession sftp,
    DragDownload drag,
    String remote,
    Directory local,
    List<Future<void>> waits,
  ) async {
    await local.create(recursive: true);
    for (final e in await sftp.list(remote)) {
      if (drag._cancelled) return;
      final target = LocalFiles.childPath(
        local.path,
        LocalFiles.safeName(e.name),
      );
      if (e.isDir && !e.isLink) {
        await _dragDir(sftp, drag, e.path, Directory(target), waits);
      } else if (!e.isDir) {
        waits.add(_dragFile(sftp, drag, e, File(target)));
      }
    }
  }

  Future<void> _dragFile(
    SftpSession sftp,
    DragDownload drag,
    RemoteEntry e,
    File local,
  ) {
    final done = Completer<void>();
    var ok = false;
    final id = _enqueueDownload(
      sftp,
      e,
      local,
      onDone: () => ok = true,
      onSettled: () {
        if (done.isCompleted) return;
        ok ? done.complete() : done.completeError(const TransferCancelled());
      },
    );
    drag._ids.add(id);
    return done.future;
  }

  // ─── Открыть локально ────────────────────────────────────────────

  /// Скачать во временную папку, открыть программой по умолчанию и
  /// заливать обратно при каждом сохранении. [onUploaded] - уведомление,
  /// [onError] - автозагрузка не удалась или остановлена.
  Future<void> openLocally(
    RemoteEntry e, {
    required void Function(String name) onUploaded,
    required void Function(String Function(AppStrings s) message) onError,
  }) async {
    final sftp = await _sftp;
    // Автозагрузка привязана к этому серверу: если хост в редакторе
    // направят на другой адрес, правки туда не уйдут.
    final target = session.target;
    final dir = await LocalFiles.editTempDir();
    final local = File(
      LocalFiles.childPath(dir.path, LocalFiles.safeName(e.name)),
    );

    _enqueueDownload(
      sftp,
      e,
      local,
      onDone: () async {
        await LocalFiles.openWithSystem(local.path);
        if (session.isDisposed || session.target != target) return;
        final edit = _LocalEdit(
          actions: this,
          entry: e,
          local: local,
          dir: dir,
          target: target,
          onUploaded: onUploaded,
          onError: onError,
        );
        await edit.start();
        session.addLocalEdit(edit);
      },
    );
  }
}

/// Наблюдение за локальной копией файла и заливка изменений на сервер.
/// Владеет подпиской и таймером; закрывается вместе с сессией или при
/// смене цели подключения.
class _LocalEdit implements LocalEditHandle {
  _LocalEdit({
    required this.actions,
    required this.entry,
    required this.local,
    required this.dir,
    required this.target,
    required this.onUploaded,
    required this.onError,
  });

  final SftpActions actions;
  final RemoteEntry entry;
  final File local;
  final Directory dir;
  final String target;
  final void Function(String name) onUploaded;
  final void Function(String Function(AppStrings s) message) onError;

  StreamSubscription<FileSystemEvent>? _sub;
  Timer? _debounce;
  late DateTime _lastModified;
  bool _closed = false;
  bool _uploading = false;

  String get _fileName => local.path.split(RegExp(r'[\\/]')).last;

  Future<void> start() async {
    _lastModified = await local.lastModified();
    _sub = dir.watch().listen(
      (event) {
        if (_closed || event.path.split(RegExp(r'[\\/]')).last != _fileName) {
          return;
        }
        _debounce?.cancel();
        _debounce = Timer(const Duration(milliseconds: 700), _check);
      },
      onError: (Object e) {
        onError((s) => s.editWatchFailed(entry.name, e));
        close();
      },
    );
  }

  Future<void> _check() async {
    if (_closed) return;
    final session = actions.session;
    if (session.isDisposed || session.target != target) {
      onError((s) => s.editTargetChanged(entry.name));
      close();
      return;
    }
    // Одна загрузка за раз: иначе более старая могла бы закончиться позже
    // и затереть на сервере новую. Сохранения за время загрузки догонит
    // повторная проверка по её окончании.
    if (_uploading) return;
    if (!await local.exists()) return;
    final m = await local.lastModified();
    if (!m.isAfter(_lastModified)) return;
    _lastModified = m;
    _uploading = true;
    try {
      final sftp = await session.sftp();
      if (_closed) return;
      actions._enqueueUpload(
        sftp,
        local,
        entry.path,
        () => onUploaded(entry.name),
        onSettled: () {
          _uploading = false;
          _check();
        },
      );
    } catch (e) {
      _uploading = false;
      onError((s) => s.editUploadFailed(entry.name, e));
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _debounce?.cancel();
    _sub?.cancel();
    actions.session.removeLocalEdit(this);
  }
}

/// Скачивание для перетаскивания: путь к копии и отмена всех её передач.
class DragDownload {
  DragDownload._(this._queue);

  final TransferQueue _queue;
  final _ids = <String>[];
  bool _cancelled = false;

  /// Локальный путь скачанного файла или папки.
  late final Future<String> path;

  /// Перетаскивание отменили: остановить ещё идущие передачи.
  void cancel() {
    _cancelled = true;
    for (final id in _ids) {
      _queue.cancel(id);
    }
  }
}
