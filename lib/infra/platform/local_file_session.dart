import 'dart:io';
import 'local_directories.dart';
import '../../domain/ports/sftp.dart';

/// Local filesystem implementation of the file-browser operations.
class LocalFileSession implements SftpSession {
  const LocalFileSession();
  @override
  Future<String> home() => LocalDirectories.home();
  @override
  Future<RemoteEntry> stat(String path) async {
    final s = await FileStat.stat(path);
    if (s.type == FileSystemEntityType.notFound) {
      throw const SftpFailure(SftpFailureCode.noSuchFile);
    }
    return RemoteEntry(
      name:
          path.split(RegExp(r'[\\/]')).where((e) => e.isNotEmpty).lastOrNull ??
          path,
      path: path,
      isDir: s.type == FileSystemEntityType.directory,
      isLink: await FileSystemEntity.isLink(path),
      size: s.size,
      modified: s.modified,
      mode: s.mode,
    );
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    try {
      final result = <RemoteEntry>[];
      await for (final e in Directory(path).list(followLinks: false)) {
        try {
          result.add(await stat(e.path));
        } on SftpFailure catch (e) {
          if (e.code != SftpFailureCode.noSuchFile) rethrow;
        }
      }
      return result;
    } on FileSystemException catch (e) {
      throw localFilesystemFailure(e);
    }
  }

  @override
  Future<void> mkdir(String path) async {
    await Directory(path).create();
  }

  @override
  Future<void> rename(String from, String to) async {
    if (await FileSystemEntity.isDirectory(from)) {
      await Directory(from).rename(to);
    } else {
      await File(from).rename(to);
    }
  }

  @override
  Future<void> removeFile(String path) async {
    await File(path).delete();
  }

  @override
  Future<void> removeDir(String path) async {
    await Directory(path).delete();
  }

  @override
  Future<void> chmod(String path, int mode) async =>
      throw const SftpFailure(SftpFailureCode.unsupported);
  @override
  Future<void> close() async {}
  @override
  Future<void> download(
    String remotePath,
    File local, {
    required CancelToken cancel,
    required ProgressCallback onProgress,
  }) async {
    final source = await File(remotePath).open();
    final sink = await local.open(mode: FileMode.write);
    try {
      var done = 0;
      while (true) {
        if (cancel.isCancelled) throw const TransferCancelled();
        final bytes = await source.read(64 * 1024);
        if (bytes.isEmpty) break;
        await sink.writeFrom(bytes);
        done += bytes.length;
        onProgress(done);
      }
    } finally {
      await source.close();
      await sink.close();
    }
  }

  @override
  Future<void> upload(
    File local,
    String remotePath, {
    required CancelToken cancel,
    required ProgressCallback onProgress,
  }) async {
    final dir = await Directory(
      File(remotePath).parent.path,
    ).createTemp('.vysh-copy-');
    final part = File('${dir.path}${Platform.pathSeparator}data');
    try {
      await download(local.path, part, cancel: cancel, onProgress: onProgress);
      if (cancel.isCancelled) throw const TransferCancelled();
      await part.rename(remotePath);
    } finally {
      await dir.delete(recursive: true);
    }
  }
}

/// Keep platform error strings out of the UI; SftpDirectory already localizes these codes.
SftpFailure localFilesystemFailure(FileSystemException e) => SftpFailure(
  switch (e.osError?.errorCode) {
    1 || 5 || 13 => SftpFailureCode.permissionDenied,
    2 || 3 => SftpFailureCode.noSuchFile,
    20 || 267 => SftpFailureCode.notADirectory,
    _ => SftpFailureCode.failed,
  },
  {'detail': e.message, 'path': e.path ?? ''},
);
