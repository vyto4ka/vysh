import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/controllers/update_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/domain/ports/secret_store.dart';
import 'package:vysh/ui/hosts/hosts_page.dart';
import 'package:vysh/ui/shell/home_switcher.dart';

import 'package:vysh/domain/models/catppuccin.dart';
import 'package:vysh/infra/platform/net_diag.dart';
import 'package:vysh/ui/theme/app_theme.dart';

class _MemoryStore implements DocumentStore {
  @override
  Object? readSync() => null;
  @override
  Future<bool> write(Object? data) async => true;
}

class _Secrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

void main() {
  testWidgets('Test HostsPage build', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secretStoreProvider.overrideWithValue(_Secrets()),
          documentStoreProvider.overrideWith((ref, name) => _MemoryStore()),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: HostsPage(),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Test HomeTabs build', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secretStoreProvider.overrideWithValue(_Secrets()),
          documentStoreProvider.overrideWith((ref, name) => _MemoryStore()),
          updateInfoProvider.overrideWith((ref) async => null),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: HomeTabs(),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  test('NetDiag отклоняет хосты с ведущим дефисом (защита от argument injection)', () async {
    final diag = NetDiag(DiagKind.ping, '-t', 22);
    final linesFuture = diag.output.toList();
    await diag.start();
    final lines = await linesFuture;
    expect(lines, hasLength(1));
    expect(lines.single.message, DiagMessage.badAddress);
  });

  test('AppSemanticColors подхватывает зелёный из Catppuccin и различает светлую/тёмную темы', () {
    final light = buildTheme(seed: Colors.blue, brightness: Brightness.light);
    final dark = buildTheme(seed: Colors.blue, brightness: Brightness.dark);
    final lightSuccess = light.extension<AppSemanticColors>()!.success;
    final darkSuccess = dark.extension<AppSemanticColors>()!.success;
    expect(lightSuccess, isNot(equals(darkSuccess)));

    final mocha = catppuccinColors('mocha', 'mauve');
    final mochaTheme = buildTheme(
      seed: mocha.seed,
      brightness: Brightness.dark,
      roles: mocha.roles[Brightness.dark],
    );
    expect(
      mochaTheme.extension<AppSemanticColors>()!.success,
      equals(catppuccinFlavor('mocha')['green']),
    );
  });
}
