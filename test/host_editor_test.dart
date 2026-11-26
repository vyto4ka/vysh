// Редактор хоста целиком: открывается, проверяет поля, сохраняет хост и пароль.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/controllers/hosts_controller.dart';
import 'package:vysh/app/controllers/settings_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/app/settings/app_settings.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/domain/ports/secret_store.dart';
import 'package:vysh/ui/hosts/host_editor.dart';

class _MemoryStore implements DocumentStore {
  _MemoryStore([this.data]);
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
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  late _Secrets secrets;
  late ProviderContainer container;

  Future<void> open(
    WidgetTester tester, {
    Host? host,
    bool duplicate = false,
    Size size = const Size(1200, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    secrets = _Secrets();
    final stores = <String, _MemoryStore>{
      // Английский интерфейс, чтобы искать кнопки по тексту.
      'settings.json': _MemoryStore(const AppSettings(language: AppLanguage.en).toJson()),
    };
    container = ProviderContainer(overrides: [
      secretStoreProvider.overrideWithValue(secrets),
      documentStoreProvider.overrideWith((ref, name) => stores.putIfAbsent(name, _MemoryStore.new)),
    ]);
    addTearDown(container.dispose);
    expect(container.read(settingsProvider).language, AppLanguage.en);
    if (host != null) container.read(hostsProvider.notifier).upsert(host);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHostEditor(context, host: host, duplicate: duplicate),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('новый хост: пустой адрес не сохраняется, заполненный - сохраняется', (tester) async {
    await open(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(container.read(hostsProvider), isEmpty); // валидатор не пустил

    await tester.enterText(find.byType(TextFormField).first, 'root@srv.example:2222');
    await tester.pump();
    final passwordField = find.byWidgetPredicate((w) => w is EditableText && w.obscureText);
    await tester.enterText(passwordField, 'secret');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final h = container.read(hostsProvider).single;
    expect((h.address, h.port, h.username), ('srv.example', 2222, 'root'));
    expect(secrets.values[passwordKey(h.id)], 'secret');
    expect(find.byType(Form), findsNothing); // панель закрылась
  });

  testWidgets('дубликат: своя подпись и новый id', (tester) async {
    const src = Host(id: 'h1', label: 'web', address: 'web.example');
    await open(tester, host: src, duplicate: true);
    expect(find.text('web (copy)'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    final hosts = container.read(hostsProvider);
    expect(hosts, hasLength(2));
    expect(hosts.map((h) => h.id).toSet(), hasLength(2));
  });

  testWidgets('способ входа «ключ» показывает поле файла ключа', (tester) async {
    await open(tester);
    expect(find.text('~/.ssh/id_ed25519'), findsNothing);
    await tester.tap(find.byIcon(Icons.key));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.vpn_key_outlined), findsOneWidget);
  });

  testWidgets('адрес и порт стоят в одну строку на ПК и обычном мобильном экране', (tester) async {
    for (final size in [const Size(1200, 1000), const Size(360, 900)]) {
      await open(tester, size: size);
      final fields = find.byType(TextFormField);
      final addressRect = tester.getRect(fields.at(0));
      final portRect = tester.getRect(fields.at(1));
      final userRect = tester.getRect(fields.at(2));

      expect(portRect.top, closeTo(addressRect.top, 0.5));
      expect(portRect.left, greaterThan(addressRect.right));
      expect(portRect.right, closeTo(userRect.right, 0.5));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('на очень узком экране порт переносится и тянется на всю ширину', (tester) async {
    await open(tester, size: const Size(300, 900));
    final fields = find.byType(TextFormField);
    final addressRect = tester.getRect(fields.at(0));
    final portRect = tester.getRect(fields.at(1));

    expect(portRect.top, greaterThan(addressRect.bottom));
    expect(portRect.left, closeTo(addressRect.left, 0.5));
    expect(portRect.right, closeTo(addressRect.right, 0.5));
    expect(tester.takeException(), isNull);
  });
}
