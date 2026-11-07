import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/controllers/backup_controller.dart';
import 'package:vysh/app/controllers/hosts_controller.dart';
import 'package:vysh/app/controllers/settings_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/domain/ports/secret_store.dart';
import 'package:vysh/domain/services/backup.dart';
import 'package:vysh/infra/secrets/backup_crypto.dart';

/// Один общий DocumentStore для всех имён (как JsonStore пишет в файлы).
class _NamedStore implements DocumentStore {
  _NamedStore(this.name);
  final String name;
  Object? data;
  @override
  Object? readSync() => data;
  @override
  Future<bool> write(Object? value) async {
    data = value;
    return true;
  }
}

class _Stores {
  final map = <String, _NamedStore>{};
  _NamedStore get(String name) => map.putIfAbsent(name, () => _NamedStore(name));
}

class _Secrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

ProviderContainer makeContainer(_Stores stores, _Secrets secrets) => ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(secrets),
        documentStoreProvider.overrideWith((ref, name) => stores.get(name)),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late _Stores stores;
  late _Secrets secrets;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vysh-backup-test');
    stores = _Stores();
    secrets = _Secrets();
  });
  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Host host(String id) => Host(
        id: id,
        label: 'h-$id',
        address: 'example.com',
        username: 'root',
      );

  test('открытый бэкап: JSON, секреты внутри', () async {
    final c = makeContainer(stores, secrets);
    addTearDown(c.dispose);
    stores.get('hosts.json').data = [host('a').toJson(), host('b').toJson()];
    stores.get('settings.json').data = {'compact': true};
    secrets.values[passwordKey('a')] = 'pw-a';

    final f = File('${tmp.path}/plain.vyshbak');
    final count = await c.read(backupControllerProvider).create(f);
    expect(count, 1);

    final text = f.readAsStringSync();
    expect(text, contains('"format": "vysh-backup"'));
    expect(text, contains('pw-a'));
    final data = await BackupController.readBackup(f);
    expect(data.hosts.length, 2);
    expect(data.secrets[passwordKey('a')], 'pw-a');
  });

  test('шифрованный бэкап: неверный пароль отклоняется, верный читается',
      () async {
    final c = makeContainer(stores, secrets);
    addTearDown(c.dispose);
    stores.get('hosts.json').data = [host('x').toJson()];
    secrets.values[passwordKey('x')] = 'pw-x';

    final f = File('${tmp.path}/enc.vyshbak');
    await c.read(backupControllerProvider).create(f, password: 'hunter22');
    // Не JSON: байтов нет '{' в первых байтах заголовка.
    final bytes = f.readAsBytesSync();
    expect(bytes.sublist(0, 12).contains(0x7b), isFalse);

    final info = await BackupController.inspect(f);
    expect(info.encrypted, true);

    await expectLater(
      BackupController.readBackup(f, password: 'wrong'),
      throwsA(isA<BackupException>()
          .having((e) => e.message, 'msg', 'wrong password')),
    );
    final data = await BackupController.readBackup(f, password: 'hunter22');
    expect(data.hosts.single['id'], 'x');
    expect(data.secrets[passwordKey('x')], 'pw-x');
  });

  test('restore пишет файлы и секреты, они видны новому контейнеру', () async {
    final c = makeContainer(stores, secrets);
    addTearDown(c.dispose);
    stores.get('hosts.json').data = [host('old').toJson()];
    final f = File('${tmp.path}/b.vyshbak');
    await c.read(backupControllerProvider).create(f, password: 'pw');
    secrets.values.clear();

    final data = await BackupController.readBackup(f, password: 'pw');
    await c.read(backupControllerProvider).restore(data);
    // Секрет вернулся в хранилище, hosts.json записан заново.
    expect(stores.get('hosts.json').data, isNotNull);
    final c2 = makeContainer(stores, secrets);
    addTearDown(c2.dispose);
    expect(c2.read(hostsProvider).single.id, 'old');
    expect(c2.read(settingsProvider).compact, isFalse);
  });

  test('шифрование: roundtrip и разный шифртекст на одинаковый вход', () {
    final a = BackupCrypto.encrypt(utf8.encode('hello') as dynamic, 'pw');
    final b = BackupCrypto.encrypt(utf8.encode('hello') as dynamic, 'pw');
    expect(a.length, b.length);
    expect(a, isNot(b)); // случайные соль и IV
    final back = BackupCrypto.decrypt(a, 'pw');
    expect(utf8.decode(back), 'hello');
  });

  test('parseBackup различает форматы и брак', () {
    final json = utf8.encode('{"format":"vysh-backup","version":1}');
    expect(parseBackup(json).encrypted, isFalse);
    expect(
      () => parseBackup(utf8.encode('{"format":"other"}')),
      throwsA(isA<BackupException>()),
    );
    expect(
      () => parseBackup(utf8.encode('not json at all')),
      throwsA(isA<BackupException>()),
    );
  });
}
