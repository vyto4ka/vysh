// Пружинные примитивы движения: PressableSurface, ExpandSection,
// LayeredSwitcher, ExpressiveSegments, SliverReveal и режим без анимаций.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vysh/app/controllers/tabs_controller.dart';
import 'package:vysh/app/dependencies.dart';
import 'package:vysh/domain/models/host.dart';
import 'package:vysh/domain/models/session_tab.dart';
import 'package:vysh/domain/ports/document_store.dart';
import 'package:vysh/domain/ports/secret_store.dart';
import 'package:vysh/ui/hosts/host_card.dart';
import 'package:vysh/ui/motion/app_motion.dart';
import 'package:vysh/ui/motion/expand_section.dart';
import 'package:vysh/ui/motion/expressive_segments.dart';
import 'package:vysh/ui/motion/layered_switcher.dart';
import 'package:vysh/ui/motion/pressable_surface.dart';
import 'package:vysh/ui/motion/sliver_reveal.dart';

class _StatefulCounter extends StatefulWidget {
  const _StatefulCounter({required this.label});
  final String label;

  @override
  State<_StatefulCounter> createState() => _StatefulCounterState();
}

class _StatefulCounterState extends State<_StatefulCounter> {
  int count = 0;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => setState(() => count++),
      child: Text('${widget.label}:$count'),
    );
  }
}

void main() {
  test('SpringCurve и AppShape сходятся к целевым значениям', () {
    expect(AppMotion.spatialCurve.transform(0), 0);
    expect(AppMotion.spatialCurve.transform(1), closeTo(1.0, 0.01));
    expect(AppShape.pressedCorner(16), lessThan(16));
  });

  testWidgets(
    'PressableSurface вызывает onTap с первого клика мышью при удержании в несколько кадров',
    (tester) async {
      var taps = 0;
      var selected = false;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            home: Scaffold(
              body: Center(
                child: PressableSurface(
                  selected: selected,
                  borderRadius: BorderRadius.circular(18),
                  selectedBorderRadius: BorderRadius.circular(12),
                  color: Colors.blueGrey,
                  selectedColor: Colors.blue,
                  onTap: () => setState(() {
                    taps++;
                    selected = !selected;
                  }),
                  child: const SizedBox(
                    width: 120,
                    height: 48,
                    child: Center(child: Text('Tap target')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // Реальный клик ЛКМ длится ~80-100 мс (несколько кадров сжатия пружины).
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Tap target')),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(taps, 1);
      expect(selected, isTrue);
    },
  );

  testWidgets(
    'ExpandSection монтирует сразу, сохраняет State после раскрытия и размонтирует после закрытия',
    (tester) async {
      var open = false;
      final animatingStates = <bool>[];

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => setState(() => open = !open),
                    child: const Text('Toggle'),
                  ),
                  ExpandSection(
                    expanded: open,
                    onAnimatingChanged: animatingStates.add,
                    child: const _StatefulCounter(label: 'Panel'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Panel:0'), findsNothing);

      await tester.tap(find.text('Toggle'));
      await tester.pump();
      // В первом же кадре открытия виджет уже смонтирован в дереве.
      expect(find.text('Panel:0'), findsOneWidget);

      // Меняем внутренний State во время анимации раскрытия.
      await tester.tap(find.text('Panel:0'));
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('Panel:1'), findsOneWidget);

      // После завершения пружины и снятия ClipRect внутренний State не сбрасывается.
      await tester.pumpAndSettle();
      expect(find.text('Panel:1'), findsOneWidget);
      expect(animatingStates, [true, false]);

      await tester.tap(find.text('Toggle'));
      await tester.pumpAndSettle();
      expect(find.text('Panel:1'), findsNothing);
    },
  );

  testWidgets('LayeredSwitcher сохраняет состояние скрытых вкладок', (
    tester,
  ) async {
    var index = 0;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => setState(() => index = 1 - index),
                  child: const Text('Switch'),
                ),
                Expanded(
                  child: LayeredSwitcher(
                    index: index,
                    children: const [
                      _StatefulCounter(label: 'A'),
                      _StatefulCounter(label: 'B'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('A:0'));
    await tester.pump();
    expect(find.text('A:1'), findsOneWidget);

    await tester.tap(find.text('Switch'));
    await tester.pumpAndSettle();
    expect(find.text('B:0'), findsOneWidget);

    await tester.tap(find.text('Switch'));
    await tester.pumpAndSettle();
    expect(find.text('A:1'), findsOneWidget);
  });

  testWidgets(
    'ExpressiveSegments переключает активный сегмент с первого клика при удержании в несколько кадров',
    (tester) async {
      var current = 'a';

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            home: Scaffold(
              body: ExpressiveSegments<String>(
                expand: true,
                segments: const [
                  ExpressiveSegment(value: 'a', label: 'First'),
                  ExpressiveSegment(value: 'b', label: 'Second'),
                  ExpressiveSegment(value: 'c', label: 'Third'),
                ],
                selected: current,
                onChanged: (v) => setState(() => current = v),
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Second')),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(current, 'b');
    },
  );

  testWidgets('SliverReveal сворачивает сливер до нулевой высоты прокрутки', (
    tester,
  ) async {
    final factor = ValueNotifier<double>(1.0);
    addTearDown(factor.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<double>(
            valueListenable: factor,
            builder: (context, f, _) => CustomScrollView(
              slivers: [
                SliverReveal(
                  factor: f,
                  sliver: SliverFixedExtentList.builder(
                    itemExtent: 50,
                    itemCount: 4,
                    itemBuilder: (_, i) => Text('Item $i'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Item 0'), findsOneWidget);
    expect(tester.getRect(find.text('Item 3')).bottom, 200);

    factor.value = 0.0;
    await tester.pump();
    expect(find.text('Item 0'), findsNothing);
  });

  testWidgets('disableAnimations отключает переходные задержки', (
    tester,
  ) async {
    var open = false;

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: StatefulBuilder(
          builder: (context, setState) => MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => setState(() => open = !open),
                    child: const Text('Toggle'),
                  ),
                  ExpandSection(
                    expanded: open,
                    child: const SizedBox(height: 50, child: Text('Instant')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Toggle'));
    await tester.pump();
    expect(tester.getSize(find.text('Instant')).height, greaterThan(0));

    await tester.tap(find.text('Toggle'));
    await tester.pump();
    expect(find.text('Instant'), findsNothing);
  });

  testWidgets(
    'HostCard открывает сессию с первого клика ЛКМ во время анимации сжатия',
    (tester) async {
      final spy = _SpyTabs();
      const server = Host(
        id: 'srv-1',
        label: 'prod-01',
        address: '10.0.0.5',
        username: 'root',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tabsProvider.overrideWith(() => spy),
            documentStoreProvider.overrideWith((ref, name) => _NullStore()),
            secretStoreProvider.overrideWithValue(_NullSecrets()),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 340,
                  height: 72,
                  child: HostCard(host: server),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('prod-01')),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(spy.openedHosts.map((h) => h.id), ['srv-1']);
    },
  );
}

class _NullStore implements DocumentStore {
  @override
  Object? readSync() => null;
  @override
  Future<bool> write(Object? data) async => true;
}

class _NullSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _SpyTabs extends TabsController {
  final openedHosts = <Host>[];

  @override
  TabsState build() => const TabsState(tabs: [], active: 0);

  @override
  String openHost(Host host, {String? password}) {
    openedHosts.add(host);
    return host.id;
  }
}
