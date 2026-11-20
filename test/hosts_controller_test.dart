import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/controllers/hosts_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/domain/ports/secret_store.dart';

class _MemoryStore implements DocumentStore {
  Object? data;
  @override
  Object? readSync() => data;
  @override
  Future<bool> write(Object? data) async {
    this.data = data;
    return true;
  }
}

class _Secrets implements SecretStore {
  final values = <String, String>{};
  bool broken = false;
  @override
  Future<String?> read(String key) async =>
      broken ? throw const SecretStoreUnavailable('test') : values[key];
  @override
  Future<void> write(String key, String value) async {
    if (broken) throw const SecretStoreUnavailable('test');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (broken) throw const SecretStoreUnavailable('test');
    values.remove(key);
  }
}

void main() {
  late _Secrets secrets;
  late _MemoryStore store;
  late ProviderContainer c;

  setUp(() {
    secrets = _Secrets();
    store = _MemoryStore();
    c = ProviderContainer(overrides: [
      secretStoreProvider.overrideWithValue(secrets),
      documentStoreProvider.overrideWith((ref, name) => store),
    ]);
  });
  tearDown(() => c.dispose());

  const host = Host(id: 'h1', label: '', address: 'a.example');

  test('пароль сохраняется, хост записывается', () async {
    final forgotten = <String>[];
    final w = await c.read(hostsProvider.notifier).saveWithPassword(host,
        password: 'pw', remember: true, forgetSessionPasswords: forgotten.add);
    expect(w, isNull);
    expect(secrets.values[passwordKey('h1')], 'pw');
    expect(c.read(hostsProvider).single.address, 'a.example');
    expect(store.data, isA<List<Object?>>());
    expect(forgotten, isEmpty); // новый хост - открытых вкладок с ним нет
  });

  test('смена пароля у существующего хоста сбрасывает пароль в открытых вкладках', () async {
    final forgotten = <String>[];
    await c.read(hostsProvider.notifier).saveWithPassword(host,
        password: 'new', remember: true, previous: host, forgetSessionPasswords: forgotten.add);
    expect(forgotten, ['h1']);
  });

  test('«не запоминать» удаляет сохранённый пароль', () async {
    secrets.values[passwordKey('h1')] = 'old';
    await c.read(hostsProvider.notifier).saveWithPassword(host,
        password: '', remember: false, previous: host, forgetSessionPasswords: (_) {});
    expect(secrets.values, isEmpty);
  });

  test('смена адреса без нового пароля удаляет сохранённый пароль', () async {
    secrets.values[passwordKey('h1')] = 'old';
    await c.read(hostsProvider.notifier).saveWithPassword(
        const Host(id: 'h1', label: '', address: 'b.example'),
        password: '', remember: true, previous: host, forgetSessionPasswords: (_) {});
    expect(secrets.values, isEmpty);
  });

  test('правка без смены адреса сохранённый пароль не трогает', () async {
    secrets.values[passwordKey('h1')] = 'old';
    await c.read(hostsProvider.notifier).saveWithPassword(
        const Host(id: 'h1', label: 'renamed', address: 'a.example'),
        password: '', remember: true, previous: host, forgetSessionPasswords: (_) {});
    expect(secrets.values[passwordKey('h1')], 'old');
  });

  test('недоступное хранилище - предупреждение, хост всё равно сохранён', () async {
    secrets.broken = true;
    final w = await c.read(hostsProvider.notifier).saveWithPassword(host,
        password: 'pw', remember: true, forgetSessionPasswords: (_) {});
    expect(w, HostSaveWarning.passwordNotSaved);
    expect(c.read(hostsProvider), hasLength(1));
  });

  test('вставка user@host:port раскладывается, набор по символу - нет', () {
    final h = pastedAddress('admin@10.0.0.5:2222', previousLength: 0)!;
    expect((h.username, h.address, h.port), ('admin', '10.0.0.5', 2222));
    expect(pastedAddress('admin@10.0.0.5:2222', previousLength: 18), isNull);
    expect(pastedAddress('example.com', previousLength: 0), isNull);
    expect(pastedAddress('example.com:2200', previousLength: 0)!.port, 2200);
  });

  test('чтение списка хостов с Map<Object?, Object?> (StandardMessageCodec)', () {
    store.data = <Object?>[
      <Object?, Object?>{
        'id': 'h2',
        'label': 'remote',
        'address': '10.0.0.2',
        'port': 2222,
        'username': 'root',
      },
    ];
    final c2 = ProviderContainer(overrides: [
      secretStoreProvider.overrideWithValue(secrets),
      documentStoreProvider.overrideWith((ref, name) => store),
    ]);
    addTearDown(c2.dispose);
    final loaded = c2.read(hostsProvider);
    expect(loaded.length, 1);
    expect(loaded.single.id, 'h2');
    expect(loaded.single.port, 2222);
  });
}
