import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/host.dart';
import '../../domain/ports/sftp.dart';

enum TransferDirection { upload, download }

enum TransferStatus { queued, running, done, failed, cancelled }

class Transfer {
  const Transfer({
    required this.id,
    required this.tabId,
    required this.direction,
    required this.name,
    required this.localPath,
    required this.remotePath,
    this.total = 0,
    this.done = 0,
    this.status = TransferStatus.queued,
    this.error,
    this.bytesPerSecond = 0,
    this.publishedUri,
  });

  final String id;
  final String tabId;
  final TransferDirection direction;
  final String name;

  /// Путь к файлу на этом устройстве.
  final String localPath;
  final String remotePath;
  final int total;
  final int done;
  final TransferStatus status;

  /// Ошибка передачи (SftpFailure и т. п.); текст собирает UI.
  final Object? error;
  final double bytesPerSecond;

  /// Android: URI копии в общей папке Download (content:// или file://) -
  /// не путь в файловой системе, хранится отдельно от [localPath].
  final String? publishedUri;

  bool get isActive =>
      status == TransferStatus.queued || status == TransferStatus.running;
  double? get progress =>
      total > 0 ? (done / total).clamp(0, 1).toDouble() : null;

  Transfer copyWith({
    int? done,
    TransferStatus? status,
    Object? error,
    double? bytesPerSecond,
    String? publishedUri,
  }) => Transfer(
    id: id,
    tabId: tabId,
    direction: direction,
    name: name,
    localPath: localPath,
    remotePath: remotePath,
    total: total,
    done: done ?? this.done,
    status: status ?? this.status,
    error: error ?? this.error,
    bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
    publishedUri: publishedUri ?? this.publishedUri,
  );
}

/// Тело передачи: выполняет работу, сообщает прогресс, уважает отмену.
typedef TransferRunner =
    Future<void> Function(CancelToken cancel, ProgressCallback onProgress);

class _Job {
  _Job(this.run, this.onDone, this.onSettled);
  final TransferRunner run;

  /// Продолжение после успешной передачи (например, открыть файл). Задача
  /// считается выполненной только после него; его ошибка - ошибка задачи.
  final FutureOr<void> Function()? onDone;

  /// Вызывается всегда, когда задача закончилась (успех, ошибка, отмена) -
  /// чтобы освободить связанные ресурсы.
  final void Function()? onSettled;
  final cancel = CancelToken();
}

final transferQueueProvider = NotifierProvider<TransferQueue, List<Transfer>>(
  TransferQueue.new,
);

/// Очередь SFTP-передач: не больше [maxParallel] одновременно.
class TransferQueue extends Notifier<List<Transfer>> {
  static const maxParallel = 3;

  /// Сколько завершённых передач помнить (на все вкладки).
  static const maxFinished = 200;
  final _jobs = <String, _Job>{};

  @override
  List<Transfer> build() => const [];

  String enqueue({
    required String tabId,
    required TransferDirection direction,
    required String name,
    required String localPath,
    required String remotePath,
    required int total,
    required TransferRunner run,
    FutureOr<void> Function()? onDone,
    void Function()? onSettled,
  }) {
    final id = newId();
    _jobs[id] = _Job(run, onDone, onSettled);
    state = [
      ...state,
      Transfer(
        id: id,
        tabId: tabId,
        direction: direction,
        name: name,
        localPath: localPath,
        remotePath: remotePath,
        total: total,
      ),
    ];
    _pump();
    return id;
  }

  void cancel(String id) {
    final t = state.where((t) => t.id == id).firstOrNull;
    if (t == null || !t.isActive) return;
    _jobs[id]?.cancel.cancel();
    if (t.status == TransferStatus.queued) {
      _jobs.remove(id)?.onSettled?.call();
      _update(id, (t) => t.copyWith(status: TransferStatus.cancelled));
    }
  }

  void cancelAllForTab(String tabId) {
    for (final t
        in state.where((t) => t.tabId == tabId && t.isActive).toList()) {
      cancel(t.id);
    }
  }

  /// Вкладку закрыли: отменить её передачи и забыть завершённые.
  void closeTab(String tabId) {
    cancelAllForTab(tabId);
    clearFinished(tabId);
  }

  void clearFinished(String tabId) {
    state = state.where((t) => t.tabId != tabId || t.isActive).toList();
  }

  /// Файл опубликован в общую Download (Android): карточка передачи должна
  /// вести туда, где он теперь лежит.
  void setPublished(String tabId, String localPath, String uri) {
    if (!ref.mounted) return;
    state = [
      for (final t in state)
        t.tabId == tabId && t.localPath == localPath
            ? t.copyWith(publishedUri: uri)
            : t,
    ];
  }

  void _pump() {
    var running = state.where((t) => t.status == TransferStatus.running).length;
    for (final t in state) {
      if (running >= maxParallel) break;
      if (t.status != TransferStatus.queued) continue;
      final job = _jobs[t.id];
      if (job == null) continue;
      running++;
      _start(t.id, job);
    }
  }

  void _start(String id, _Job job) {
    _update(id, (t) => t.copyWith(status: TransferStatus.running));
    final sw = Stopwatch()..start();
    var lastEmit = 0;
    var latestDone = 0;
    var lastBytes = 0;
    var lastTime = 0;
    var speed = 0.0;

    void onProgress(int done) {
      latestDone = done;
      final now = sw.elapsedMilliseconds;
      if (now - lastEmit < 120) return; // не чаще ~8 раз в секунду
      final dt = now - lastTime;
      if (dt > 0) {
        final instant = (done - lastBytes) * 1000 / dt;
        speed = speed == 0 ? instant : speed * 0.7 + instant * 0.3;
      }
      lastBytes = done;
      lastTime = now;
      lastEmit = now;
      _update(id, (t) => t.copyWith(done: done, bytesPerSecond: speed));
    }

    job
        .run(job.cancel, onProgress)
        .then((_) async {
          if (job.cancel.isCancelled) {
            _update(id, (t) => t.copyWith(status: TransferStatus.cancelled));
          } else {
            await job.onDone?.call();
            _update(
              id,
              (t) => t.copyWith(
                status: TransferStatus.done,
                done: t.total > 0 ? t.total : latestDone,
              ),
            );
          }
        })
        .catchError((Object e) {
          final cancelled = e is TransferCancelled || job.cancel.isCancelled;
          _update(
            id,
            (t) => t.copyWith(
              status: cancelled
                  ? TransferStatus.cancelled
                  : TransferStatus.failed,
              error: cancelled ? null : e,
            ),
          );
        })
        .whenComplete(() {
          _jobs.remove(id);
          try {
            job.onSettled?.call();
          } catch (_) {}
          _trimHistory();
          _pump();
        });
  }

  void _trimHistory() {
    if (!ref.mounted) return;
    final finished = state.where((t) => !t.isActive).length;
    if (finished <= maxFinished) return;
    // Выбрасываем самые старые завершённые, активные не трогаем.
    var drop = finished - maxFinished;
    final next = <Transfer>[];
    for (final t in state) {
      if (!t.isActive && drop > 0) {
        drop--;
        continue;
      }
      next.add(t);
    }
    state = next;
  }

  void _update(String id, Transfer Function(Transfer) f) {
    if (!ref.mounted) return;
    state = [for (final t in state) t.id == id ? f(t) : t];
  }
}
