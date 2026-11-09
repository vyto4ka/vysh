import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/domain/ports/secret_store.dart';
import 'package:vysh/ui/hosts/hosts_page.dart';
import 'package:vysh/ui/shell/home_switcher.dart';

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
}
