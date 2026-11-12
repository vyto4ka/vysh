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
import 'package:vysh/app/windows/detached_windows.dart';
import 'package:vysh/ui/shell/tab_drag.dart';
import 'package:vysh/ui/shell/tab_strip.dart';
import 'package:vysh/ui/theme/app_theme.dart';

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

class _Detached extends DetachedWindows {
  final calls = <String>[];
  @override
  Map<String, String> build() => {};
  @override
  Future<void> detach(String id) async {
    calls.add(id);
    state = {...state, id: 'test-window'};
  }
}

class _ManyTabs extends TabsController {
  @override
  TabsState build() => TabsState(
    tabs: List.generate(
      12,
      (i) => SessionTab(
        id: 'tab-$i',
        title: 'Session ${i + 1}',
        host: Host(id: 'host-$i', label: '', address: 'host-$i'),
      ),
    ),
    active: 1,
  );
}

Future<ProviderContainer> workspace(
  WidgetTester tester, {
  TabsController Function()? tabs,
}) async {
  final container = ProviderContainer(
    overrides: [
      tabsProvider.overrideWith(tabs ?? _Tabs.new),
      documentStoreProvider.overrideWith((ref, name) => _Store()),
      detachedWindowsProvider.overrideWith(_Detached.new),
      nativeTabDragProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(seed: Colors.purple, brightness: Brightness.dark),
        home: const Scaffold(
          body: Column(
            children: [
              TabStrip(),
              Expanded(child: SessionWorkspace(home: Text('Home'))),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('layout selection follows the menu and visible split', (
    tester,
  ) async {
    final c = await workspace(tester);
    final button = find.byWidgetPredicate(
      (widget) =>
          widget is IconButton &&
          widget.tooltip == 'Layout and session actions',
    );
    bool selected() => tester.widget<IconButton>(button).isSelected!;
    expect(selected(), isFalse);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(selected(), isTrue);
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(selected(), isFalse);
    c.read(splitTabProvider.notifier).select('two');
    await tester.pumpAndSettle();
    expect(selected(), isTrue);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unsplit'));
    await tester.pumpAndSettle();
    expect(selected(), isFalse);
    expect(c.read(splitTabProvider), isNull);
    await tester.pumpWidget(const SizedBox());
  });

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
  testWidgets('explicit split menu selects a second tab and vertical layout', (
    tester,
  ) async {
    final c = await workspace(tester);
    await tester.tap(find.byTooltip('Layout and session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open a tab below'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second').last);
    await tester.pumpAndSettle();
    expect(c.read(splitTabProvider), 'two');
    expect(c.read(splitLayoutProvider).axis, Axis.vertical);
    await tester.tap(find.text('Second').first);
    await tester.pump();
    expect(c.read(tabsProvider).active, 1);
    expect(c.read(workspaceFocusProvider), 'two');
    expect(find.byType(SessionView), findsNWidgets(2));
    expect(find.text('Two panes'), findsNothing);
    expect(find.text('One pane'), findsNothing);
    await tester.tap(find.byTooltip('Layout and session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unsplit'));
    await tester.pump();
    expect(c.read(splitTabProvider), isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('dragging a tab to a highlighted drop zone creates a split', (
    tester,
  ) async {
    final c = await workspace(tester);
    final tab = find.byWidgetPredicate(
      (w) => w is Draggable<String> && w.data == 'two',
    );
    final drag = await tester.startGesture(tester.getCenter(tab));
    await drag.moveBy(const Offset(0, 80));
    await tester.pump();
    expect(find.text('Open on the right'), findsOneWidget);
    await drag.moveTo(tester.getCenter(find.text('Open on the right')));
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect(c.read(splitTabProvider), 'two');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('switching to an offscreen tab reveals it in the strip', (
    tester,
  ) async {
    final c = await workspace(tester, tabs: _ManyTabs.new);
    c.read(tabsProvider.notifier).activate(12);
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.text('Session 12'));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(
      rect.right,
      lessThan(tester.view.physicalSize.width / tester.view.devicePixelRatio),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('a rejected drop outside the native window requests tear-off', (
    tester,
  ) async {
    final c = await workspace(tester);
    final tab = find.byWidgetPredicate(
      (w) => w is Draggable<String> && w.data == 'one',
    );
    final drag = await tester.startGesture(tester.getCenter(tab));
    await drag.moveBy(const Offset(0, 60));
    await tester.pump();
    await drag.moveTo(const Offset(-150, 180));
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect((c.read(detachedWindowsProvider.notifier) as _Detached).calls, [
      'one',
    ]);
    expect(c.read(detachedWindowsProvider).containsKey('one'), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
