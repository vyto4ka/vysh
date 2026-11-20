import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../domain/ports/sftp.dart';

/// SFTP на dartssh2.
class DartSsh2Sftp implements SftpSession {
  DartSsh2Sftp(this._c);

  final SftpClient _c;

  /// Сколько ждать следующую порцию данных при скачивании.
  static const _stallTimeout = Duration(seconds: 60);

  @override
  Future<String> home() => _guard(() => _c.absolute('.'));

  @override
  Future<List<RemoteEntry>> list(String path) => _guard(() async {
        final names = await _c.listdir(path);
        final entries = <RemoteEntry>[];
        for (final n in names) {
          if (n.filename == '.' || n.filename == '..') continue;
          entries.add(_entry(remoteJoin(path, n.filename), n.filename, n.attr));
        }
        // Для симлинков узнаём, указывают ли они на папку.
        await Future.wait([
          for (var i = 0; i < entries.length; i++)
            if (entries[i].isLink)
              _c.stat(entries[i].path).then((a) {
                final e = entries[i];
                entries[i] = RemoteEntry(
                  name: e.name,
                  path: e.path,
                  isDir: a.isDirectory,
                  isLink: true,
                  size: a.size ?? e.size,
                  modified: e.modified,
                  mode: e.mode,
                );
              }).catchError((_) {}),
        ]);
        return entries;
      });

  @override
  Future<RemoteEntry> stat(String path) => _guard(
    () async => _entry(
      path,
      remoteBasename(path),
      await _c.stat(path, followLink: false),
    ),
  );

  RemoteEntry _entry(String path, String name, SftpFileAttrs a) => RemoteEntry(
        name: name,
        path: path,
        isDir: a.isDirectory,
        isLink: a.isSymbolicLink,
        size: a.size ?? 0,
        modified: a.modifyTime == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(a.modifyTime! * 1000),
        mode: a.mode?.value,
      );

  @override
  Future<void> mkdir(String path) => _guard(() => _c.mkdir(path));

  @override
  Future<void> rename(String from, String to) => _guard(() => _c.rename(from, to));

  @override
  Future<void> removeFile(String path) => _guard(() => _c.remove(path));

  @override
  Future<void> removeDir(String path) => _guard(() => _c.rmdir(path));

  @override
  Future<void> chmod(String path, int mode) =>
      _guard(() => _c.setStat(path, SftpFileAttrs(mode: SftpFileMode.value(mode & 0xFFF))));

  @override
  Future<void> download(
    String remotePath,
    File local, {
    required CancelToken cancel,
    required ProgressCallback onProgress,
  }) =>
      _guard(() async {
        if (cancel.isCancelled) throw const TransferCancelled();
        final file = await _c.open(remotePath);
        RandomAccessFile? out;
        StreamSubscription<Uint8List>? sub;
        Timer? stall;
        final finished = Completer<void>();
        void fail(Object e) {
          if (!finished.isCompleted) finished.completeError(e);
        }

        try {
          final o = out = await local.open(mode: FileMode.write);
          void resetStall() {
            stall?.cancel();
            stall = Timer(
              _stallTimeout,
              () => fail(SftpFailure(
                  SftpFailureCode.stalled, {'seconds': '${_stallTimeout.inSeconds}'})),
            );
          }

          // Отмена срабатывает сразу, а не «со следующей порцией данных»,
          // которой у зависшего канала может и не быть.
          cancel.onCancel(() => fail(const TransferCancelled()));
          resetStall();
          var bytes = 0;
          sub = file.read().listen(
            (chunk) {
              // Пока порция пишется на диск, следующие не принимаем:
              // медленный диск не копит весь файл в памяти.
              sub!.pause();
              o.writeFrom(chunk).then((_) {
                bytes += chunk.length;
                onProgress(bytes);
                resetStall();
                if (!finished.isCompleted) sub!.resume();
              }, onError: fail);
            },
            onError: fail,
            onDone: () {
              if (!finished.isCompleted) finished.complete();
            },
            cancelOnError: true,
          );
          await finished.future;
        } finally {
          stall?.cancel();
          // Отмена чтения ждёт ответа сервера на текущий запрос - не блокируемся.
          unawaited(sub?.cancel().catchError((_) {}));
          try {
            await out?.close();
          } catch (_) {}
          await _closeQuietly(file);
        }
      });

  @override
  Future<void> upload(
    File local,
    String remotePath, {
    required CancelToken cancel,
    required ProgressCallback onProgress,
  }) =>
      _guard(() async {
        if (cancel.isCancelled) throw const TransferCancelled();
        SftpFileAttrs? existing;
        try {
          existing = await _c.stat(remotePath, followLink: false);
        } on SftpStatusError catch (e) {
          if (e.code != SftpStatusCode.noSuchFile) rethrow;
        }
        if (existing != null && existing.isDirectory) {
          throw SftpFailure(SftpFailureCode.isDirectory, {'path': remotePath});
        }

        // Симлинк заменять нельзя (rename превратил бы его в обычный файл) -
        // пишем прямо в файл, на который он указывает.
        if (existing != null && existing.isSymbolicLink) {
          await _writeTo(remotePath, local, cancel, onProgress, truncate: true);
          return;
        }

        final tmp = remoteJoin(
          remoteParent(remotePath),
          '.${remoteBasename(remotePath)}.vysh-${_rand()}.part',
        );
        try {
          await _writeTo(tmp, local, cancel, onProgress, exclusive: true);
        } on SftpStatusError catch (e) {
          if (e.code == SftpStatusCode.permissionDenied && existing != null) {
            // В папку писать нельзя, а в сам файл можно (например, общий
            // файл в чужой папке). Временный файл не создать - пишем напрямую.
            await _removeQuietly(tmp);
            await _writeTo(remotePath, local, cancel, onProgress, truncate: true);
            return;
          }
          await _removeQuietly(tmp);
          rethrow;
        } catch (_) {
          await _removeQuietly(tmp);
          rethrow;
        }

        try {
          final mode = existing?.mode?.value;
          if (mode != null) {
            try {
              await _c.setStat(tmp, SftpFileAttrs(mode: SftpFileMode.value(mode & 0xFFF)));
            } catch (_) {
              // Права - не повод терять загруженное.
            }
          }
          if (cancel.isCancelled) throw const TransferCancelled();
          await _replace(tmp, remotePath, existed: existing != null);
        } catch (_) {
          await _removeQuietly(tmp);
          rethrow;
        }
      });

  Future<void> _writeTo(
    String path,
    File local,
    CancelToken cancel,
    ProgressCallback onProgress, {
    bool truncate = false,
    bool exclusive = false,
  }) async {
    var mode = SftpFileOpenMode.create | SftpFileOpenMode.write;
    if (truncate) mode = mode | SftpFileOpenMode.truncate;
    if (exclusive) mode = mode | SftpFileOpenMode.exclusive;
    final file = await _c.open(path, mode: mode);
    try {
      final stream = local
          .openRead()
          .map((c) => c is Uint8List ? c : Uint8List.fromList(c));
      final writer = file.write(stream, onProgress: onProgress);
      cancel.onCancel(() => writer.abort());
      await writer.done;
      if (cancel.isCancelled) throw const TransferCancelled();
    } finally {
      await _closeQuietly(file);
    }
  }

  /// Поставить [from] на место [to]. С posix-rename (OpenSSH) это одна
  /// атомарная операция; без него - старый файл отодвигается в сторону и
  /// возвращается обратно, если замена не удалась.
  Future<void> _replace(String from, String to, {required bool existed}) async {
    try {
      await _c.rename(from, to);
      return;
    } on SftpStatusError {
      if (!existed) rethrow;
    }
    final aside = '$to.vysh-old-${_rand()}';
    await _c.rename(to, aside);
    try {
      await _c.rename(from, to);
    } catch (_) {
      try {
        await _c.rename(aside, to);
      } catch (_) {}
      rethrow;
    }
    await _removeQuietly(aside);
  }

  Future<void> _removeQuietly(String path) async {
    try {
      await _c.remove(path).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  static Future<void> _closeQuietly(SftpFile file) async {
    try {
      await file.close().timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  static String _rand() {
    final r = Random.secure();
    return List.generate(4, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  Future<void> close() async {
    try {
      await _c.close();
    } catch (_) {}
  }

  /// Переводим ошибки SFTP в коды [SftpFailureCode].
  Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on TransferCancelled {
      rethrow;
    } on SftpFailure {
      rethrow;
    } on SftpStatusError catch (e) {
      final detail = {if (e.message.isNotEmpty) 'detail': e.message};
      throw switch (e.code) {
        SftpStatusCode.noSuchFile => const SftpFailure(SftpFailureCode.noSuchFile),
        SftpStatusCode.permissionDenied => const SftpFailure(SftpFailureCode.permissionDenied),
        SftpStatusCode.failure => SftpFailure(SftpFailureCode.failed, detail),
        SftpStatusCode.opUnsupported => const SftpFailure(SftpFailureCode.unsupported),
        11 => const SftpFailure(SftpFailureCode.exists),
        _ => SftpFailure(SftpFailureCode.other, {'code': '${e.code}', ...detail}),
      };
    } on SftpError catch (e) {
      throw SftpFailure(SftpFailureCode.other, {'detail': e.message});
    } on FileSystemException catch (e) {
      throw SftpFailure(SftpFailureCode.localFile, {'detail': e.osError?.message ?? e.message});
    } on SSHError catch (e) {
      throw SftpFailure(SftpFailureCode.connection, {'detail': '$e'});
    }
  }
}
