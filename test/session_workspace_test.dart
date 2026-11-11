import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/models/session_tab.dart';
import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/ui/shell/session_workspace.dart';
import 'package:vysh/ui/shell/ui_state.dart';
import 'package:vysh/ui/terminal/session_view.dart';

class _Store implements DocumentStore {
  @override
  Object? readSync() => null;
  @override
  Future<bool> write(Object? data) async => true;
}

class _Tabs extends TabsController {
  @override
  TabsState build() => const TabsState(
    tabs: [
      SessionTab(
        id: 'one',
        title: 'First',
        host: Host(id: 'h1', label: '', address: 'one'),
      ),
      SessionTab(
        id: 'two',
        title: 'Second',
        host: Host(id: 'h2', label: '', address: 'two'),
      ),
    ],
    active: 1,
  );
}

void main() {
  testWidgets('splitting and returning preserve both session views', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        tabsProvider.overrideWith(_Tabs.new),
        documentStoreProvider.overrideWith((ref, name) => _Store()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SessionWorkspace(home: Text('Home'))),
        ),
      ),
    );
    final first = tester.state(
      find.byWidgetPredicate(
        (w) => w is SessionView && w.tab.id == 'one',
        skipOffstage: false,
      ),
    );
    final second = tester.state(
      find.byWidgetPredicate(
        (w) => w is SessionView && w.tab.id == 'two',
        skipOffstage: false,
      ),
    );
    container.read(splitTabProvider.notifier).select('two');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(SessionView), findsNWidgets(2));
    container.read(splitTabProvider.notifier).select(null);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester.state(
        find.byWidgetPredicate(
          (w) => w is SessionView && w.tab.id == 'one',
          skipOffstage: false,
        ),
      ),
      same(first),
    );
    expect(
      tester.state(
        find.byWidgetPredicate(
          (w) => w is SessionView && w.tab.id == 'two',
          skipOffstage: false,
        ),
      ),
      same(second),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
