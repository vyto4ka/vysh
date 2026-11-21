// Пружинные примитивы движения: PressableSurface, ExpandSection,
// LayeredSwitcher, ExpressiveSegments, SliverReveal и режим без анимаций.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('PressableSurface вызывает onTap и завершает пружину', (
    tester,
  ) async {
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

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Tap target')),
    );
    await tester.pump(const Duration(milliseconds: 40));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(taps, 1);
    expect(selected, isTrue);
  });

  testWidgets(
    'ExpandSection монтирует содержимое сразу и размонтирует после закрытия',
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
                    child: const SizedBox(height: 60, child: Text('Payload')),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Payload'), findsNothing);

      await tester.tap(find.text('Toggle'));
      await tester.pump();
      // В первом же кадре открытия виджет уже смонтирован в дереве.
      expect(find.text('Payload'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('Payload'), findsOneWidget);
      expect(animatingStates, [true, false]);

      await tester.tap(find.text('Toggle'));
      await tester.pumpAndSettle();
      expect(find.text('Payload'), findsNothing);
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

  testWidgets('ExpressiveSegments переключает активный сегмент', (
    tester,
  ) async {
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

    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(current, 'b');
  });

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
}
