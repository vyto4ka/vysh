import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'local_files.dart';

/// Browsing and local shells must agree on an accessible starting directory.
/// Android's HOME/current directory often points outside the app sandbox.
class LocalDirectories {
  static Future<String> home() async {
    if (Platform.isAndroid && await LocalFiles.hasStorageAccess()) {
      final externalRoot =
          await LocalFiles.externalStorageRoot() ?? '/storage/emulated/0';
      if (await readable(externalRoot)) return externalRoot;
    }
    return resolve(
      android: Platform.isAndroid,
      candidates: [
        if (Platform.isWindows) ...[
          Platform.environment['USERPROFILE'],
          if (Platform.environment['HOMEDRIVE'] != null &&
              Platform.environment['HOMEPATH'] != null)
            '${Platform.environment['HOMEDRIVE']}${Platform.environment['HOMEPATH']}',
        ] else
          Platform.environment['HOME'],
      ],
      documents: () async {
        final docs = (await getApplicationDocumentsDirectory()).path;
        // На Android в корне documents лежит служебная папка `vysh/` с
        // hosts.json и settings.json — отдаём отдельную подпапку `files/`.
        return Platform.isAndroid ? '$docs/files' : docs;
      },
    );
  }

  static Future<String> resolve({
    required bool android,
    required List<String?> candidates,
    required Future<String> Function() documents,
  }) async {
    if (!android) {
      for (final candidate in candidates) {
        if (candidate != null &&
            candidate.isNotEmpty &&
            await readable(candidate)) {
          return candidate;
        }
      }
    }
    try {
      final path = await documents();
      await Directory(path).create(recursive: true);
      if (await readable(path)) return path;
    } catch (_) {}
    if (!android && await readable(Directory.current.path)) {
      return Directory.current.path;
    }
    // A private fallback, never / or shared Android storage requiring a grant.
    return (await Directory.systemTemp.createTemp('vysh-files-')).path;
  }

  static Future<bool> readable(String path) async {
    try {
      await Directory(path).list().take(1).drain<void>();
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
