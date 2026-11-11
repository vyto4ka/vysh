import 'dart:io';
import '../../domain/ports/sftp.dart';
import '../../infra/platform/local_file_session.dart';
import '../../infra/platform/local_files.dart';

/// Decisions are scoped to a single user-initiated copy operation.
enum CopyChoice { replace, skip, keepBoth, cancel }

class CopyDecision {
  const CopyDecision(this.choice, {this.applyToAll = false});
  final CopyChoice choice;
  final bool applyToAll;
}

typedef ResolveCopyConflict = Future<CopyDecision> Function(String path);

class FileCopy {
  FileCopy({
    required this.source,
    required this.target,
    required this.resolve,
    required this.cancel,
    required this.progress,
    this.sameFilesystem = false,
  });
  final bool sameFilesystem;
  final SftpSession source;
  final SftpSession target;
  final ResolveCopyConflict resolve;
  final CancelToken cancel;
  final ProgressCallback progress;
  CopyChoice? _remembered;
  int copied = 0;
  int skipped = 0;
  int _bytes = 0;

  void _check() {
    if (cancel.isCancelled) throw const TransferCancelled();
  }

  Future<RemoteEntry?> _stat(String path) async {
    try {
      return await target.stat(path);
    } on SftpFailure catch (e) {
      if (e.code == SftpFailureCode.noSuchFile) return null;
      rethrow;
    }
  }

  String child(String dir, String name) {
    // Reject remote path traversal; sanitize names only for local destinations.
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\')) {
      throw const SftpFailure(SftpFailureCode.failed, {
        'detail': 'Invalid file name',
      });
    }
    return target is LocalFileSession
        ? LocalFiles.childPath(dir, LocalFiles.safeName(name))
        : remoteJoin(dir, name);
  }

  Future<void> copy(RemoteEntry entry, String destination) async {
    _check();
    if (entry.isLink) {
      skipped++;
      return;
    }
    final same =
        sameFilesystem ||
        identical(source, target) ||
        source is LocalFileSession && target is LocalFileSession;
    var originalPath = Uri.file(
      entry.path,
      windows: source is LocalFileSession && Platform.isWindows,
    ).normalizePath().path;
    var targetPath = Uri.file(
      destination,
      windows: target is LocalFileSession && Platform.isWindows,
    ).normalizePath().path;
    if (same && source is LocalFileSession) {
      originalPath = (await File(
        entry.path,
      ).resolveSymbolicLinks()).replaceAll('\\', '/');
      final parent = await Directory(
        File(destination).parent.path,
      ).resolveSymbolicLinks();
      targetPath = LocalFiles.childPath(
        parent,
        remoteBasename(destination.replaceAll('\\', '/')),
      ).replaceAll('\\', '/');
      if (Platform.isWindows) {
        originalPath = originalPath.toLowerCase();
        targetPath = targetPath.toLowerCase();
      }
    }
    if (same && !entry.isDir && originalPath == targetPath) {
      skipped++;
      return;
    }
    if (same &&
        entry.isDir &&
        (originalPath == targetPath ||
            targetPath.startsWith('$originalPath/'))) {
      throw const SftpFailure(SftpFailureCode.failed, {
        'detail': 'Cannot copy a folder into itself',
      });
    }
    var existing = await _stat(destination);
    if (existing?.isLink ?? false) {
      throw SftpFailure(SftpFailureCode.exists, {'path': destination});
    }
    if (entry.isDir && (existing == null || existing.isDir)) {
      if (existing == null) await target.mkdir(destination);
      for (final e in await source.list(entry.path)) {
        await copy(e, child(destination, e.name));
      }
      return;
    }
    final temp = await Directory.systemTemp.createTemp('vysh-copy-');
    try {
      final file = File('${temp.path}/source');
      if (!entry.isDir) {
        await source.download(
          entry.path,
          file,
          cancel: cancel,
          onProgress: (_) {},
        );
        _check();
        if (existing != null &&
            !existing.isDir &&
            await file.length() == existing.size) {
          final other = File('${temp.path}/target');
          await target.download(
            destination,
            other,
            cancel: cancel,
            onProgress: (_) {},
          );
          if (await _equal(file, other)) {
            skipped++;
            return;
          }
        }
      }
      if (existing != null) {
        final decision = _remembered == null
            ? await resolve(destination)
            : CopyDecision(_remembered!);
        _check();
        if (decision.applyToAll) _remembered = decision.choice;
        switch (decision.choice) {
          case CopyChoice.cancel:
            throw const TransferCancelled();
          case CopyChoice.skip:
            skipped++;
            return;
          case CopyChoice.keepBoth:
            final original = destination;
            var n = 1;
            do {
              final dot = original.lastIndexOf('.');
              final slash = original.replaceAll('\\', '/').lastIndexOf('/');
              destination = !entry.isDir && dot > slash + 1
                  ? '${original.substring(0, dot)} (${n++})${original.substring(dot)}'
                  : '$original (${n++})';
            } while (await _stat(destination) != null);
            existing = null;
          case CopyChoice.replace:
            // Never delete a directory (possibly with unrelated files) to replace it with a file.
            if (entry.isDir != existing.isDir) {
              throw SftpFailure(SftpFailureCode.exists, {'path': destination});
            }
        }
      }
      _check();
      if (entry.isDir) {
        await target.mkdir(destination);
        for (final e in await source.list(entry.path)) {
          await copy(e, child(destination, e.name));
        }
      } else {
        await target.upload(
          file,
          destination,
          cancel: cancel,
          onProgress: (n) => progress(_bytes + n),
        );
        _bytes += await file.length();
        copied++;
      }
    } finally {
      await temp.delete(recursive: true);
    }
  }

  Future<bool> _equal(File a, File b) async {
    final left = await a.open();
    final right = await b.open();
    try {
      while (true) {
        _check();
        final x = await left.read(64 * 1024);
        final y = await right.read(64 * 1024);
        if (x.length != y.length) return false;
        for (var i = 0; i < x.length; i++) {
          if (x[i] != y[i]) return false;
        }
        if (x.isEmpty) return true;
      }
    } finally {
      await left.close();
      await right.close();
    }
  }
}
