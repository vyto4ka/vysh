import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dependencies.dart';
import '../controllers/hosts_controller.dart';
import '../controllers/settings_controller.dart';
import '../../domain/ports/secret_store.dart';
import '../../domain/services/backup.dart';
import '../../infra/secrets/backup_crypto.dart';

/// Создание и восстановление резервной копии профиля: hosts.json,
/// settings.json, known_hosts.json и сохранённые пароли из SecretStore.
class BackupController {
  BackupController(this._ref);

  final Ref _ref;

  /// Собрать данные бэкапа. Пароли включаются, когда SecretStore доступен:
  /// при недоступном хранилище бэкап без паролей лучше, чем никакого.
  Future<BackupData> _collect() async {
    final secrets = <String, String>{};
    final store = _ref.read(secretStoreProvider);
    final hosts = _ref.read(hostsProvider);
    for (final h in hosts) {
      for (final key in [passwordKey(h.id), passphraseKey(h.id)]) {
        try {
          final v = await store.read(key);
          if (v != null && v.isNotEmpty) secrets[key] = v;
        } on Object {
          // Нет keyring-демона и т.п. - секреты не попадут в бэкап.
        }
      }
    }
    Object? read(String name) =>
        _ref.read(documentStoreProvider(name)).readSync();
    return BackupData(
      hosts: [for (final h in hosts) h.toJson()],
      settings: read('settings.json'),
      knownHosts: read('known_hosts.json'),
      secrets: secrets,
      createdAt: DateTime.now(),
    );
  }

  /// Записать бэкап в [file]. С пустым [password] - открытый JSON,
  /// с паролем - AES-256-GCM. Возвращает число секретов в бэкапе.
  Future<int> create(File file, {String password = ''}) async {
    final data = await _collect();
    final plain = Uint8List.fromList(utf8.encode(data.encodeJson()));
    final bytes =
        password.isEmpty ? plain : BackupCrypto.encrypt(plain, password);
    final tmp = File('${file.path}.vysh-tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(file.path);
    return data.secrets.length;
  }

  /// Проверить файл бэкапа (шифрован ли, число хостов). Без пароля.
  static Future<({bool encrypted, int hosts, DateTime? createdAt})> inspect(
      File file) async {
    final bytes = await file.readAsBytes();
    final parsed = parseBackup(bytes);
    if (parsed.encrypted) {
      return (encrypted: true, hosts: 0, createdAt: null);
    }
    final d = parsed.data!;
    return (encrypted: false, hosts: d.hosts.length, createdAt: d.createdAt);
  }

  /// Расшифровать и разобрать файл бэкапа (проверка пароля перед записью).
  static Future<BackupData> readBackup(File file, {String password = ''}) async {
    final bytes = await file.readAsBytes();
    final parsed = parseBackup(bytes);
    final Uint8List plain;
    if (parsed.encrypted) {
      if (password.isEmpty) throw const BackupException('password required');
      plain = BackupCrypto.decrypt(bytes, password);
    } else {
      plain = bytes;
    }
    return BackupData.fromJson(jsonDecode(utf8.decode(plain)));
  }

  /// Восстановить данные в профиль: секреты - в защищённое хранилище,
  /// hosts.json / settings.json / known_hosts.json - теми же атомарными
  /// записями, что и в обычной работе.
  ///
  /// Контроллеры при этом живут в памяти и затёрли бы восстановленное при
  /// первом же изменении, поэтому после записи [reload] переводит их на
  /// чтение с диска. Пароли хостов, которых нет в бэкапе, остаются в
  /// хранилище как есть (лишние ключи никуда не ведут).
  Future<void> restore(BackupData data) async {
    final store = _ref.read(secretStoreProvider);
    for (final e in data.secrets.entries) {
      await store.write(e.key, e.value);
    }
    Future<void> write(String name, Object? value) async {
      final ok = await _ref.read(documentStoreProvider(name)).write(value);
      if (!ok) throw BackupException('cannot write $name');
    }

    await write('hosts.json', data.hosts);
    await write('settings.json', data.settings);
    await write('known_hosts.json', data.knownHosts);
  }

  /// Перечитать hosts.json, settings.json и known_hosts.json с диска.
  void reload() {
    _ref.invalidate(hostsProvider);
    _ref.invalidate(settingsProvider);
    _ref.invalidate(knownHostsProvider);
  }
}

final backupControllerProvider =
    Provider<BackupController>((ref) => BackupController(ref));
